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
require File.expand_path('../../test_helper', __FILE__)

# sync_user_status decides, for every user on every run, whether to lock, archive
# or activate the account. It is four nested conditions over the account's current
# state, the LDAP flags, and the "must be member of" group, and until now nothing
# tested it directly — it was only ever exercised incidentally by the full-sync
# tests, which cover a couple of paths out of eleven.
#
# The fixture's lock condition is `flags.include? '[disabled]'`, so '[disabled]'
# means locked on LDAP and any other string means not locked. The symbol :deleted
# is what sync_user passes when the user is gone from the directory.
class SyncUserStatusTest < ActiveSupport::TestCase
  fixtures :auth_sources, :users, :groups_users, :settings, :custom_fields
  fixtures :email_addresses if Redmine::VERSION::MAJOR >= 3

  setup do
    @auth_source = auth_sources(:auth_sources_001)
    @ldap_setting = LdapSetting.find_by_auth_source_ldap_id(@auth_source.id)
  end

  # -- an active account ----------------------------------------------------

  test "an active user gone from ldap should be archived" do
    user = active_user

    sync_status user, :deleted

    assert user.reload.locked?, 'archiving locks the account'
    assert_empty user.groups, 'archiving also strips group memberships'
  end

  test "an active user flagged locked on ldap should be locked" do
    user = active_user

    sync_status user, '[disabled]'

    assert user.reload.locked?
  end

  test "an active user should be locked when the caller says so regardless of flags" do
    user = active_user

    sync_status user, nil, true

    assert user.reload.locked?
  end

  test "an active user not flagged on ldap should be left alone" do
    user = active_user

    sync_status user, '[enabled]'

    assert user.reload.active?
  end

  test "an active user outside the required group should be locked" do
    user = active_user # loadgeek is in rynever, not in therss
    require_group 'therß'

    sync_status user, '[enabled]'

    assert user.reload.locked?
  end

  test "an active user inside the required group should be left alone" do
    user = active_user
    require_group 'rynever'

    sync_status user, '[enabled]'

    assert user.reload.active?
  end

  # -- a locked account -----------------------------------------------------

  test "a locked user should stay locked when nothing asks for activation" do
    user = locked_user

    sync_status user, nil

    assert user.reload.locked?
  end

  test "a locked user should be activated when ACTIVATE_USERS is on" do
    user = locked_user
    AuthSourceLdap.activate_users = true

    sync_status user, nil

    assert user.reload.active?
  end

  test "a locked user flagged locked on ldap should stay locked even with ACTIVATE_USERS" do
    user = locked_user
    AuthSourceLdap.activate_users = true

    sync_status user, '[disabled]'

    assert user.reload.locked?
  end

  test "a locked user gone from ldap should stay locked even with ACTIVATE_USERS" do
    user = locked_user
    AuthSourceLdap.activate_users = true

    sync_status user, :deleted

    assert user.reload.locked?
  end

  test "a locked user outside the required group should stay locked" do
    user = locked_user
    require_group 'rynever' # dlopper2 belongs to no group

    sync_status user, '[enabled]'

    assert user.reload.locked?
  end

  # Worth knowing rather than assuming: membership of the required group activates a
  # locked account on its own, without ACTIVATE_USERS. So an account an
  # administrator locked by hand comes back at the next sync, as long as a required
  # group is configured and the user is in it. Long-standing behaviour, pinned here
  # so a change to it is a deliberate one.
  test "a locked user inside the required group is activated without ACTIVATE_USERS" do
    user = users(:users_010) # rubycalm, a member of rynever
    user.lock!
    AuthSourceLdap.activate_users = false
    require_group 'rynever'

    sync_status user, '[enabled]'

    assert user.reload.active?
  end

  private
    def active_user
      users(:loadgeek).tap {|u| assert u.active?, 'fixture should start active' }
    end

    def locked_user
      users(:users_005).tap {|u| assert u.locked?, 'fixture should start locked' } # dlopper2
    end

    def require_group(name)
      @ldap_setting.required_group = name
      assert @ldap_setting.save, @ldap_setting.errors.full_messages.join(', ')
    end

    def sync_status(user, flags, locked = false)
      @auth_source.send(:sync_user_status, user, flags, locked)
    end
end
