# encoding: utf-8
# Copyright (C) 2011-2013  The Redmine LDAP Sync Authors
#
# This file is part of Redmine LDAP Sync.
#
# Redmine LDAP Sync is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Redmine LDAP Sync is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Redmine LDAP Sync.  If not, see <http://www.gnu.org/licenses/>.
class LdapTest
  include Redmine::I18n
  include LdapSync::EntityManager
  include ActiveModel::Conversion
  include ActiveModel::Validations
  extend ActiveModel::Naming

  attr_accessor :setting, :bind_user, :bind_password, :test_users, :test_groups, :messages, :user_attrs, :group_attrs, :users_at_ldap, :groups_at_ldap, :non_dynamic_groups, :dynamic_groups, :users_locked_by_group, :admin_users, :user_changes, :users_status, :groups_status, :trace_errors

  delegate :auth_source_ldap, :to => :setting
  delegate :users, :to => :auth_source_ldap

  validates_presence_of :bind_user, :bind_password, :if => :connect_as_user?

  def initialize(setting)
    setting.active = true

    @setting = setting
    @messages = ''
    @user_changes = {:enabled => [], :locked => [], :deleted => []}
    @users_at_ldap = {}
    @groups_at_ldap = {}
    @non_dynamic_groups = []
    @dynamic_groups = {}
    @users_locked_by_group = []
    @admin_users = []
    @users_status = {}
    @groups_status = {}
    @trace_errors = []
  end

  def initialize_ldap_con(login, password)
    auth_source_ldap.send(:initialize_ldap_con, login, password)
  end

  def run_with_users_and_groups(users, groups)
    with_ldap_connection(@bind_user, @bind_password) do |ldap|
      @user_changes = ldap_users
      users.each do |login|
        user_data = find_user(ldap, login, nil)
        if user_data
          @user_attrs ||= user_data
          flags = setting.has_account_flags? ? user_data[n(:account_flags)].first : nil
          local_user, other_auth = local_user_for(login)
          group_changes = groups_changes(local_user || User.new {|u| u.login = login })
          fields = get_user_fields(login, user_data, :include_required => true)
          current_fields = current_user_fields(local_user, fields.keys)
          rows = group_rows(ldap, local_user, group_changes)
          verdict = user_verdict(local_user, other_auth, flags, group_changes)
          verdict = :in_sync if verdict == :would_update && !pending_changes?(fields, current_fields, rows)
          users_at_ldap[login] = {
            :fields => fields,
            :current_fields => current_fields,
            :groups => group_changes,
            :group_rows => rows,
            :raw => raw_attributes(user_data),
            :flags => flags,
            :locked => (account_locked?(flags) if setting.has_account_flags?),
            :redmine => redmine_user_state(local_user),
            :verdict => verdict,
            :can_apply => local_user.present? && !other_auth
          }
        else
          users_at_ldap[login] = in_ldap_without_filter?(ldap, login) ? :excluded_by_filter : :not_found
        end
      end

      user_changes[:enabled].each do |login|
        group_changes = groups_changes(User.new {|u| u.login = login })
        enabled_groups = group_changes[:added].map(&:downcase)

        if setting.has_admin_group?
          admin_users << login if enabled_groups.include? setting.admin_group.downcase
        end

        if setting.has_required_group?
          users_locked_by_group << login unless enabled_groups.include? setting.required_group.downcase
        end
      end if setting.has_admin_group? || setting.has_required_group?

      groups.each do |name|
        group_data = find_group(ldap, name, nil)
        if group_data
          @group_attrs ||= group_data
          groupname = group_data[n(:groupname)].try(:first) || name
          local_group = ::Group.where("LOWER(lastname) = ?", name.mb_chars.downcase.to_s).first
          groups_at_ldap[name] = {
            :fields => get_group_fields(name, group_data),
            :matches_pattern => !setting.has_groupname_pattern? || !!(setting.groupname_regexp =~ groupname),
            :redmine_group => local_group.present?,
            :member_rows => group_member_rows(ldap, local_group, group_data)
          }
        else
          groups_at_ldap[name] = :not_found
        end
      end

      find_all_groups(ldap, nil, n(:groupname)) do |entry|
        if !setting.has_groupname_pattern? || entry.first =~ /#{setting.groupname_pattern}/
          non_dynamic_groups << entry.first
        end
      end
      if setting.sync_dyngroups?
        find_all_dyngroups(ldap, :update_cache => true)
        dynamic_groups.reject! {|(k, v)| k !~ /#{setting.groupname_pattern}/ } if setting.has_groupname_pattern?
      end
    end
  rescue Exception => e
    error(e.message + e.backtrace.join("\n  "))
  end

  # Whether the diff for a user contains anything a sync run would change
  def pending_changes?(fields, current_fields, group_rows)
    return true if current_fields && fields.any? {|k, v| current_fields[k].to_s.strip != v.to_s.strip }

    group_rows.any? {|row| [:added, :removed].include?(row[:status]) }
  end

  # Full LDAP <-> Redmine diff over all users, bucketed by what a
  # synchronization would do with each login.
  def run_all_users
    with_ldap_connection(@bind_user, @bind_password) do |ldap|
      @user_changes = ldap_users
      local = ::User.logged.pluck(:login, :status, :auth_source_id).
        each_with_object({}) {|(l, s, a), h| h[l.mb_chars.downcase.to_s] = [s, a] }

      user_changes[:enabled].each do |login|
        status, auth = local[login.mb_chars.downcase.to_s]
        bucket =
          if status.nil?
            setting.create_users? ? :would_create : :not_created
          elsif auth != auth_source_ldap.id
            :skipped_other_auth
          elsif status == ::User::STATUS_LOCKED
            :locked_in_redmine
          else
            :would_update
          end
        (users_status[bucket] ||= []) << login
      end

      user_changes[:locked].each do |login|
        status, auth = local[login.mb_chars.downcase.to_s]
        bucket =
          if status.nil?
            :locked_not_created
          elsif auth != auth_source_ldap.id
            :skipped_other_auth
          elsif status == ::User::STATUS_LOCKED
            :stays_locked
          else
            :would_lock_flags
          end
        (users_status[bucket] ||= []) << login
      end

      user_changes[:deleted].each {|login| (users_status[:would_archive] ||= []) << login }
    end
  rescue Exception => e
    error(e.message + e.backtrace.join("\n  "))
  end

  # Full LDAP <-> Redmine diff over all groups, bucketed by what a
  # synchronization would do with each group.
  def run_all_groups
    with_ldap_connection(@bind_user, @bind_password) do |ldap|
      ldap_names = []
      find_all_groups(ldap, nil, n(:groupname)) {|entry| ldap_names << entry.first unless entry.first.blank? }

      local_names = ::Group.givable.pluck(:lastname)
      local_set = local_names.map {|name| name.mb_chars.downcase.to_s }.to_set

      ldap_names.uniq.sort_by(&:downcase).each do |name|
        matches = !setting.has_groupname_pattern? || !!(setting.groupname_regexp =~ name)
        bucket =
          if !matches
            :excluded_by_pattern
          elsif local_set.include?(name.mb_chars.downcase.to_s)
            :in_sync
          elsif setting.create_groups?
            :would_create
          else
            :not_created
          end
        (groups_status[bucket] ||= []) << name
      end

      ldap_set = ldap_names.map {|name| name.mb_chars.downcase.to_s }.to_set
      local_names.sort_by(&:downcase).each do |name|
        next if ldap_set.include?(name.mb_chars.downcase.to_s)

        (groups_status[:only_in_redmine] ||= []) << name
      end
    end
  rescue Exception => e
    error(e.message + e.backtrace.join("\n  "))
  end

  def self.human_attribute_name(attr, *args)
    attr = attr.to_s.sub(/_id$/, '')

    l("field_#{name.underscore.gsub('/', '_')}_#{attr}", :default => ["field_#{attr}".to_sym, attr])
  end

  def persisted?; true; end

  REDACTED_ATTRIBUTES = %w(userpassword unicodepwd sambantpassword sambalmpassword krbprincipalkey ipanthash).freeze

  private
    # The Redmine user for a login plus whether it belongs to a different
    # auth source (the sync skips those).
    def local_user_for(login)
      user = ::User.where("LOWER(login) = ?", login.mb_chars.downcase.to_s).first
      [user, user.present? && user.auth_source_id != auth_source_ldap.id]
    end

    # Whether the login exists on LDAP when the configured user filter is NOT
    # applied — distinguishes "excluded by the filter" from "does not exist".
    def in_ldap_without_filter?(ldap, login)
      filter = Net::LDAP::Filter.eq(:objectclass, setting.class_user) &
               Net::LDAP::Filter.eq(setting.login, login)
      ldap_search(ldap, {:base => setting.base_dn, :filter => filter,
                         :attributes => [setting.login], :return_result => true}).present?
    end

    # The user's complete group membership as diff rows: groups the sync would
    # add or remove, unchanged LDAP-managed memberships, plus memberships the
    # sync leaves alone (pattern mismatch or not present on LDAP at all).
    def group_rows(ldap, local_user, group_changes)
      rows = group_changes[:added].to_a.sort_by(&:downcase).map {|g| {:name => g, :status => :added} }

      current = local_user ? local_user.groups.map {|g| g.name } : []
      return rows if current.empty?

      deleted = group_changes[:deleted].map {|g| g.mb_chars.downcase.to_s }
      on_ldap = ldap_group_names(ldap, current)
      re = setting.groupname_regexp

      current.sort_by(&:downcase).each do |name|
        dc = name.mb_chars.downcase.to_s
        status = if deleted.include?(dc)
          :removed
        elsif setting.has_groupname_pattern? && !(re =~ name)
          :unmanaged
        elsif !on_ldap.include?(dc)
          :not_on_ldap
        else
          :unchanged
        end
        rows << {:name => name, :status => status}
      end
      rows
    end

    # Which of the given group names exist on LDAP (downcased set)
    def ldap_group_names(ldap, names)
      return Set.new if names.empty?

      filter = names.map {|g| Net::LDAP::Filter.eq(setting.groupname, g) }.reduce(:|)
      found = find_all_groups(ldap, filter, n(:groupname)) || []
      found.map {|e| Array(e).first.to_s.mb_chars.downcase.to_s }.to_set
    end

    # The Redmine user's current values for the fields the sync would apply,
    # so the test can show an actual diff instead of just the LDAP side.
    def current_user_fields(user, keys)
      return nil if user.nil?

      keys.each_with_object({}) do |key, fields|
        fields[key] = if key =~ /\A\d+\z/
          user.custom_field_value(key.to_i)
        elsif user.respond_to?(key)
          user.send(key)
        end
      end
    end

    def redmine_user_state(user)
      return nil if user.nil?

      status = if user.active?
        :active
      elsif user.locked?
        :locked
      else
        :registered
      end
      { :status => status, :auth_source => user.auth_source.try(:name) }
    end

    # What a synchronization would do with this user, mirroring
    # sync_users/sync_user_status (with the worker's ACTIVATE_USERS=false).
    def user_verdict(user, other_auth, flags, group_changes)
      return :skipped_other_auth if other_auth

      ldap_locked = setting.has_account_flags? && account_locked?(flags)

      if user.nil?
        return :locked_not_created if ldap_locked

        return setting.create_users? ? :would_create : :not_created
      end

      required_ok = true
      if setting.has_required_group?
        current = user.groups.map {|g| g.name.mb_chars.downcase.to_s }
        added = group_changes[:added].map {|g| g.mb_chars.downcase.to_s }
        deleted = group_changes[:deleted].map {|g| g.mb_chars.downcase.to_s }
        required_ok = ((current | added) - deleted).include?(setting.required_group.mb_chars.downcase.to_s)
      end

      if user.locked?
        if !ldap_locked && setting.has_required_group? && required_ok
          :would_activate
        else
          :stays_locked
        end
      elsif ldap_locked
        :would_lock_flags
      elsif !required_ok
        :would_lock_required_group
      else
        :would_update
      end
    end

    # Resolves the tested group's direct members on LDAP to logins.
    # Nested group members are not resolved.
    def ldap_member_logins(ldap, group_data)
      logins =
        case setting.group_membership
        when 'on_groups'
          memberids = group_data[n(:member)].to_a
          if setting.user_memberid == setting.login
            memberids
          else
            map = find_all_users(ldap, ns(:login, :user_memberid)).each_with_object({}) do |e, h|
              h[e[n(:user_memberid)].first] = e[n(:login)].first
            end
            memberids.map {|m| map[m] || m }
          end
        else # 'on_members'
          groupid = group_data[n(:groupid)].try(:first)
          if groupid.blank?
            []
          else
            find_all_users(ldap, ns(:login, :user_groups)).
              select {|e| e[n(:user_groups)].include?(groupid) }.
              map {|e| e[n(:login)].first }
          end
        end

      if setting.has_primary_group? && (gid = group_data[n(:primary_group)].try(:first)).present?
        logins |= find_all_users(ldap, ns(:login, :primary_group)).
          select {|e| e[n(:primary_group)].try(:first) == gid }.
          map {|e| e[n(:login)].first }
      end

      logins.compact.uniq
    end

    # Member diff between the Redmine group and the LDAP group: members the
    # user syncs would add or remove, unchanged ones, LDAP members that never
    # sync (outside the user filter), and Redmine members the sync leaves
    # alone (different auth source / local accounts).
    def group_member_rows(ldap, local_group, group_data)
      ldap_logins = ldap_member_logins(ldap, group_data)
      ldap_set = ldap_logins.map {|l| l.mb_chars.downcase.to_s }.to_set
      syncable = Set.new((user_changes[:enabled] + user_changes[:locked]).map {|l| l.mb_chars.downcase.to_s })

      current = local_group ? local_group.users.map {|u| [u.login, u.auth_source_id] } : []
      current_set = current.map {|login, _| login.mb_chars.downcase.to_s }.to_set

      rows = []
      ldap_logins.sort_by(&:downcase).each do |login|
        dc = login.mb_chars.downcase.to_s
        next if current_set.include?(dc)

        rows << {:name => login, :status => syncable.include?(dc) ? :added : :not_synced}
      end
      current.sort_by {|login, _| login.downcase }.each do |login, auth_id|
        dc = login.mb_chars.downcase.to_s
        status = if ldap_set.include?(dc)
          :unchanged
        elsif auth_id == auth_source_ldap.id
          :removed
        else
          :unmanaged
        end
        rows << {:name => login, :status => status}
      end
      rows
    end

    # The raw LDAP entry as a printable {attribute => [values]} hash, so the
    # test output shows the admin the actual data the mappings and the
    # locked-account expression operate on. Password-ish attributes are
    # redacted, binary values summarized, long values truncated.
    def raw_attributes(entry)
      entry.attribute_names.sort.each_with_object({}) do |attr, hash|
        hash[attr.to_s] =
          if REDACTED_ATTRIBUTES.include?(attr.to_s.downcase)
            ['[FILTERED]']
          else
            Array(entry[attr]).map {|value| printable_value(value) }
          end
      end
    end

    def printable_value(value)
      str = value.to_s.dup.force_encoding('UTF-8')
      return "<binary, #{value.to_s.bytesize} bytes>" if !str.valid_encoding? || str =~ /[\x00-\x08\x0B\x0C\x0E-\x1F]/
      str.length > 120 ? "#{str[0, 117]}..." : str
    end

    def update_dyngroups_cache!(mem_cache)
      @dynamic_groups = Hash.new{|h,k| h[k] = Set.new}
      mem_cache.each do |(login, groups)|
        dyngroups_cache.write(login, groups)

        groups.each {|group| @dynamic_groups[group] << login }
      end
    end

    def closure_cache
      @closure_cache ||= ActiveSupport::Cache.lookup_store(:memory_store)
    end

    def dyngroups_cache
      @dyngroups_cache ||= ActiveSupport::Cache.lookup_store(:memory_store)
    end

    def parents_cache
      @parents_cache ||= ActiveSupport::Cache.lookup_store(:memory_store)
    end

    def trace(msg = "", options = {})
      @messages += "#{msg}\n" if msg
      # errors get surfaced prominently in the result; the rest of the log
      # stays available behind them for debugging
      @trace_errors << msg.to_s.split("\n").first if options[:level] == :error && msg
    end

    def running_rake?; true; end
    def dyngroups_fresh?; false; end
end
