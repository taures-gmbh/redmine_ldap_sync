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
require File.expand_path('../base', __FILE__)

# The parts of the settings page that only exist in a browser: the JS that applies
# a base-settings preset, shows the attribute fields belonging to the selected
# membership/nesting mode, and runs the test tab over AJAX.
#
# Fields are addressed by id (ldap_setting_*) rather than by label. Labels are
# translated and have been renamed more than once - account_flags alone went from
# "Account flags (user)" to "Lock state attribute" - and a test that breaks on a
# reworded label reports a failure where there is no defect.
class LdapSync::LdapSettingTest < LdapSync::UiTestCase
  setup do
    log_user('admin', 'admin')
  end

  def test_the_configuration_listing_links_to_the_setting
    visit '/admin/ldap_sync'

    within 'tr#ldap-config-1' do
      click_link 'LDAP test server'
    end

    assert_current_path '/admin/ldap_sync/1/edit', :ignore_query => true
    assert_selector 'h2', :text => 'LDAP test server'
  end

  def test_a_base_settings_preset_should_fill_in_the_schema_fields
    visit_ldap_setting

    select 'Samba LDAP', :from => 'base_settings'

    assert_equal 'sambaSamAccount', value_of('class_user')
    assert_equal 'sambaGroupMapping', value_of('class_group')
    assert_equal 'on_groups', value_of('group_membership')
    assert_equal 'member', value_of('member')
    assert_equal 'dn', value_of('user_memberid')

    select 'Active Directory (with nested groups)', :from => 'base_settings'

    assert_equal 'on_parents', value_of('nested_groups')
    assert_equal 'flags.to_i & 2 != 0', value_of('account_locked_test')
    assert_equal 'samaccountname', value_of('groupname')
    assert_equal 'useraccountcontrol', value_of('account_flags')
    assert_equal 'distinguishedname', value_of('groupid')
    assert_equal 'member', value_of('member_group')
    assert_equal 'distinguishedname', value_of('group_memberid')
  end

  def test_the_lock_fields_should_be_mirrored_onto_the_test_tab
    visit_ldap_setting

    fill_in 'ldap_setting_account_flags', :with => 'sambaAcctFlags'

    # The test tab evaluates unsaved settings, so it carries its own copies of the
    # two lock fields, kept in step with the real ones by JS.
    assert_equal 'sambaAcctFlags', find('#mirror_account_flags', :visible => :all).value
  end

  def test_group_membership_should_show_only_the_attributes_it_uses
    visit_ldap_setting

    select 'On the user class', :from => 'ldap_setting_group_membership'

    assert_hidden 'member', 'user_memberid'
    assert_shown  'user_groups', 'groupid'

    select 'On the group class', :from => 'ldap_setting_group_membership'

    assert_hidden 'user_groups', 'groupid'
    assert_shown  'member', 'user_memberid'
  end

  def test_nested_groups_should_show_only_the_attributes_it_uses
    visit_ldap_setting

    select 'Disabled', :from => 'ldap_setting_nested_groups'

    assert_hidden 'member_group', 'group_memberid', 'parent_group', 'group_parentid'

    select 'Membership on the parent class', :from => 'ldap_setting_nested_groups'

    assert_hidden 'parent_group', 'group_parentid'
    assert_shown  'member_group', 'group_memberid'

    select 'Membership on the member class', :from => 'ldap_setting_nested_groups'

    assert_hidden 'member_group', 'group_memberid'
    assert_shown  'parent_group', 'group_parentid'
  end

  # The TTL field only makes sense for one of the three dynamic-group modes, and
  # only JS enforces that. Uncovered when the show/hide pair became a single
  # toggle(), which is exactly the kind of change that silently inverts.
  def test_the_dyngroups_ttl_should_only_show_for_the_ttl_mode
    visit_ldap_setting

    select 'Enabled with a TTL', :from => 'ldap_setting_dyngroups'
    assert_selector '#dyngroups-cache-ttl', :visible => true

    select 'Enabled', :from => 'ldap_setting_dyngroups'
    assert_no_selector '#dyngroups-cache-ttl', :visible => true

    select 'Disabled', :from => 'ldap_setting_dyngroups'
    assert_no_selector '#dyngroups-cache-ttl', :visible => true
  end

  # Replaces the old test of the text/plain dump this tab used to render, removed
  # in v2.6 along with the interface it asserted.
  def test_the_test_tab_should_report_a_single_user_as_a_diff
    visit_ldap_setting(1, :tab => 'test')

    assert_selector '#test-result', :text => /not executed/i

    fill_in 'test_users', :with => 'tweetmicro'
    find('#commit-test-submit').click
    wait_for_ajax

    within '#test-result' do
      assert_text 'tweetmicro'
      # the field-level diff table, and a verdict badge for the entity
      assert_selector 'table.ldap-diff'
      assert_selector 'span.ldap-verdict'
      assert_text 'tweetmicro@fakemail.com'
    end

    assert_no_selector '#test-result', :text => 'ldap_test.rb'
  end

  def test_the_test_tab_should_list_all_groups
    visit_ldap_setting(1, :tab => 'test')

    # by data attribute, not by label: the JS keys the test case off it, and a
    # reworded button should not fail this test
    find('.commit-test-button[data-test-case="all_groups"]').click
    wait_for_ajax

    within '#test-result' do
      assert_selector 'div.ldap-test-bucket'
      # every listed name links back to the single-entity test
      assert_selector 'a.ldap-test-entity'
      assert_text 'Therß'
    end
  end

  private
    def value_of(attribute)
      find("#ldap_setting_#{attribute}", :visible => :all).value
    end

    def assert_hidden(*attributes)
      attributes.each do |attribute|
        assert_no_selector "#ldap_setting_#{attribute}", :visible => true,
                           :wait => 2
      end
    end

    def assert_shown(*attributes)
      attributes.each do |attribute|
        assert_selector "#ldap_setting_#{attribute}", :visible => true
      end
    end
end
