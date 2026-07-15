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
module LdapSettingsHelper
  def config_css_classes(config)
    "ldap_setting #{config.active? ? 'enabled' : 'disabled' }"
  end

  def change_status_link(config)
    if config.active?
      link_to l(:button_disable), disable_ldap_setting_path(config), :method => :put, :class => 'icon icon-disable'
    else
      link_to l(:button_enable), enable_ldap_setting_path(config), :method => :put, :class => 'icon icon-enable'
    end
  end

  def ldap_setting_tabs(form)
    [
      {:name => 'LdapSettings', :partial => 'ldap_settings', :label => :label_ldap_settings, :form => form},
      {:name => 'SynchronizationActions', :partial => 'synchronization_actions', :label => :label_synchronization_actions, :form => form},
      {:name => 'Test', :partial => 'test', :label => :label_test, :form => form}
    ]
  end

  def options_for_nested_groups
    [
      [l(:option_nested_groups_disabled), ''],
      [l(:option_nested_groups_on_parents), :on_parents],
      [l(:option_nested_groups_on_members), :on_members]
    ]
  end

  def options_for_group_membeship
    [
      [l(:option_group_membership_on_groups), :on_groups],
      [l(:option_group_membership_on_members), :on_members]
    ]
  end

  def options_for_dyngroups
    [
      [l(:option_dyngroups_disabled), ''],
      [l(:option_dyngroups_enabled), :enabled],
      [l(:option_dyngroups_enabled_with_ttl), :enabled_with_ttl]
    ]
  end

  def options_for_sync_on_login
    [
      [l(:option_sync_on_login_user_fields_and_groups), :user_fields_and_groups],
      [l(:option_sync_on_login_user_fields), :user_fields],
      [l(:option_sync_on_login_disabled), '']
    ]
  end

  def options_for_users_search_scope
    [
      [l(:option_users_search_subtree), :subtree],
      [l(:option_users_search_onelevel), :onelevel]
    ]
  end

  def group_fields
    has_group_ldap_attrs = @ldap_setting.has_group_ldap_attrs?

    GroupCustomField.all.map do |f|
      SyncField.new(
        f.id,
        f.name,
        f.is_required?,
        @ldap_setting.sync_group_fields? && @ldap_setting.group_fields_to_sync.include?(f.id.to_s),
        has_group_ldap_attrs ? @ldap_setting.group_ldap_attrs[f.id.to_s] : '',
        f.default_value
      )
    end
  end

  def user_fields
    has_user_ldap_attrs = @ldap_setting.has_user_ldap_attrs?

    (User::STANDARD_FIELDS + UserCustomField.all).map do |f|
      if f.is_a?(String)
        id        = f
        name      = l("field_#{f}")
        required  = true
        ldap_attr = @ldap_setting.auth_source_ldap.send("attr_#{f}")
        default   = ''
      else
        id        = f.id
        name      = f.name
        required  = f.is_required?
        ldap_attr = has_user_ldap_attrs ? @ldap_setting.user_ldap_attrs[id.to_s] : ''
        default   = f.default_value
      end

      sync = @ldap_setting.sync_user_fields? && @ldap_setting.user_fields_to_sync.include?(id.to_s)

      SyncField.new(id, name, required, sync, ldap_attr, default)
    end
  end

  def options_for_base_settings
    options = [[l(:option_custom), '']]
    options += base_settings.collect {|k, h| [l(:"base_settings_#{k}", :default => h['name']), k] }.sort
    options_for_select(options, current_base)
  end

  # Entity names in listings link to the single-entity test (the JS fills the
  # test field and re-runs).
  def test_entity_links(names, type)
    safe_join(names.map {|name|
      link_to name, '#', :class => 'ldap-test-entity', :data => { :type => type, :name => name }
    }, ', ')
  end

  # One badge language for every test mode: green = in sync, yellow = the
  # sync would change something, red = blocked (pattern/config), grey = the
  # sync leaves it alone.
  def verdict_badge(text, tone)
    content_tag(:span, text, :class => "ldap-verdict ldap-verdict-#{tone}")
  end

  USER_VERDICT_TONES = {
    :in_sync => 'ok',
    :would_create => 'warn', :would_update => 'warn', :would_activate => 'warn',
    :would_lock_flags => 'warn', :would_lock_required_group => 'warn',
    :stays_locked => 'muted', :locked_not_created => 'muted', :skipped_other_auth => 'muted',
    :not_created => 'fail'
  }.freeze

  def user_verdict_badge(verdict)
    verdict_badge(l(:"text_verdict_#{verdict}"), USER_VERDICT_TONES[verdict] || 'muted')
  end

  def group_state_badge(data, changed_count, create_groups)
    if !data[:matches_pattern]
      verdict_badge(l(:text_badge_group_not_synced), 'fail')
    elsif !data[:redmine_group]
      create_groups ? verdict_badge(l(:text_verdict_would_create), 'warn') :
                      verdict_badge(l(:text_badge_group_not_created), 'fail')
    elsif changed_count > 0
      verdict_badge(l(:text_badge_group_pending, :count => changed_count), 'warn')
    else
      verdict_badge(l(:text_group_in_sync), 'ok')
    end
  end

  # :new when the user doesn't exist yet, :changed / :unchanged otherwise
  def field_diff_status(current_fields, key, new_value)
    return :new if current_fields.nil?

    current_fields[key].to_s.strip == new_value.to_s.strip ? :unchanged : :changed
  end

  def diff_row_class(status)
    case status
    when :changed then 'ldap-row-changed'
    when :new, :added then 'ldap-row-added'
    when :removed then 'ldap-row-removed'
    when :unmanaged, :not_on_ldap, :not_synced then 'ldap-row-muted'
    else ''
    end
  end

  # One membership row: name (drill-down link) once, then plain ✓/— marks for
  # "is currently in the Redmine group/user" and "is on the LDAP side" — the
  # status column says what the sync does about it.
  def membership_diff_row(row, entity_type, label_prefix, name_prefix = nil)
    in_redmine = [:unchanged, :removed, :unmanaged, :not_on_ldap].include?(row[:status])
    on_ldap = [:unchanged, :added, :not_synced].include?(row[:status])

    name_cell = test_entity_links([row[:name]], entity_type)
    name_cell = safe_join(["#{name_prefix}: ", name_cell]) if name_prefix

    content_tag(:tr, :class => diff_row_class(row[:status])) do
      safe_join([
        content_tag(:td, name_cell),
        content_tag(:td, in_redmine ? '✓' : '—', :class => 'ldap-diff-mark'),
        content_tag(:td, on_ldap ? '✓' : '—', :class => 'ldap-diff-mark'),
        content_tag(:td, l(:"label_diff_#{label_prefix}_#{row[:status]}"), :class => 'ldap-diff-status')
      ])
    end
  end

  def redmine_account_line(state)
    return l(:text_redmine_account_missing) if state.nil?

    parts = [l(:"status_#{state[:status]}")]
    parts << "#{l(:field_auth_source)}: #{state[:auth_source]}" if state[:auth_source].present?
    parts.join(', ')
  end

  def group_fields_list(fields)
    return "    #{l(:label_no_fields)}\n" if fields.empty?

    fields.map do |(k, v)|
      "    #{group_field_name k} = #{v}\n"
    end.join
  end

  private
    def user_field_name(field)
      return l("field_#{field}") if field !~ /\A\d+\z/

      UserCustomField.find_by_id(field.to_i).name
    end

    def group_field_name(field)
      GroupCustomField.find_by_id(field.to_i).name
    end

    def baseable_fields
      LdapSetting::LDAP_ATTRIBUTES + LdapSetting::CLASS_NAMES + %w( group_membership nested_groups )
    end

    def current_base
      base_settings.each do |key, hash|
        return key if hash.slice(*baseable_fields).all? {|k,v| @ldap_setting.send(k) == (v || '') }
      end
      ''
    end

    def base_settings
      @base_settings if defined? @base_settings

      config_dir = File.join(Redmine::Plugin.find(:redmine_ldap_sync).directory, 'config')
      default = baseable_fields.inject({}) {|h, k| h[k] = ''; h }
      @base_settings = YAML::load_file(File.join(config_dir, 'base_settings.yml'))
      @base_settings.each {|k,h| h.reverse_merge!(default) }
    end

    class SyncField < Struct.new :id, :name, :required, :synchronize, :ldap_attribute, :default_value
      def synchronize?; synchronize; end
      def required?; required; end
    end
end
