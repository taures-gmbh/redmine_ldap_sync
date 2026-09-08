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
module LdapSync
  class Hooks < Redmine::Hook::ViewListener

    # Add a question CSS class
    def view_layouts_base_html_head(_context = {})
      stylesheet_link_tag 'ldap_sync.css', :plugin => 'redmine_ldap_sync'
    end

    # Sync on login for authentications that never touch User.try_to_login!.
    #
    # The alias in LdapSync::Infectors::User only covers Redmine's own
    # username/password path. An SSO plugin (redmine_oauth and friends) sets the
    # session directly, so an OIDC user's fields and groups would only refresh on
    # the next full sync run. This hook fires from
    # ApplicationController#successful_authentication, which every login path
    # goes through, so it closes that gap without knowing about any SSO plugin.
    #
    # Deliberately quiet on failure: not being able to enqueue must not turn a
    # valid login into an error page. LdapSyncAllWorker will catch up.
    def controller_account_success_authentication_after(context = {})
      user = context[:user]
      return unless user.is_a?(::User) && user.sync_on_login?

      # try_to_login! already synced this one; don't pay for a second bind.
      already = ::LdapSync::Hooks.synced_on_login_user_id
      ::LdapSync::Hooks.synced_on_login_user_id = nil
      return if already == user.id

      # Out of band: a real bind measured ~480 ms, which would land on the
      # login request itself. The worker re-checks everything, so nothing is
      # decided here beyond "this login is worth a sync".
      ::LdapSyncUserWorker.perform_async(user.id)
    rescue StandardError => e
      Rails.logger.error(
        "ldap_sync: on-login sync failed for '#{user.try(:login)}': #{e.class}: #{e.message}"
      )
    end

    # Set by the try_to_login! path so the hook can tell the two apart. Cleared
    # on every read, and again before each try_to_login!, so a login that syncs
    # but never reaches successful_authentication (a locked account, say) cannot
    # leave the flag set for the next request on this Puma thread.
    def self.synced_on_login_user_id
      Thread.current[:ldap_sync_synced_on_login_user_id]
    end

    def self.synced_on_login_user_id=(id)
      Thread.current[:ldap_sync_synced_on_login_user_id] = id
    end

  end
end