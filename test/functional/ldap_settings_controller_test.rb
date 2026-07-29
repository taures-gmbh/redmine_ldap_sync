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

class LdapSettingsControllerTest < ActionController::TestCase
  fixtures :auth_sources, :users, :settings, :custom_fields

  setup do
    Setting.clear_cache
    @auth_source = auth_sources(:auth_sources_001)
    @ldap_setting = LdapSetting.find_by_auth_source_ldap_id(@auth_source.id)
    @request.session[:user_id] = 1
  end

  # assigns / assert_template were extracted from Rails into the
  # rails-controller-testing gem, which Redmine does not bundle. Where the intent
  # was "the action set this up", @controller.view_assigns replaces assigns();
  # where it was "this template rendered", assert on the rendered output instead.
  def test_should_get_index
    get :index
    assert_response :success
    assert_not_nil @controller.view_assigns['ldap_settings']

    assert_select "table tr", 3
    assert_select "a", :text => 'LDAP test server', :count => 1
    assert_select "td", :text => '127.0.0.1', :count => 1
    # Was a duplicate of the line above; the second auth source's host is .2, so
    # the listing of the second row went unasserted.
    assert_select "td", :text => '127.0.0.2', :count => 1
  end

  def test_should_get_base_settings_js
    get :base_settings, :format => 'js'
    assert_response :success
    assert_equal 'text/javascript', response.media_type
    # base_settings.js.erb assigns the presets as JSON to a global
    assert_match /\Avar base_settings = \{.*\};/, response.body
    assert_includes response.body, 'active_directory'
  end

  def test_should_redirect_to_get_edit_on_get_show
    get :show, params: { id: 1 }
    assert_redirected_to edit_ldap_setting_path(1)
  end

  def test_should_get_edit
    get :edit, params: { id: @auth_source.id }
    assert_response :success
  end

  def test_should_get_404
    get :edit, params: { id: 999 }
    assert_response :not_found
  end

  def test_should_disable_ldap_setting
    # Given that
    assert @ldap_setting.active?, "LdapSetting must be enabled"
    assert_equal 'member', @ldap_setting.member_group

    # When we do
    get :disable, params: { id: @ldap_setting.id }
    assert_redirected_to ldap_settings_path
    assert_match /success/, flash[:notice]

    # We should have
    ldap_setting = LdapSetting.find_by_auth_source_ldap_id(@ldap_setting.id)
    assert_equal 'member', ldap_setting.member_group, 'LdapSetting is not the same'
    assert !ldap_setting.active?, "LdapSetting must be disabled"
  end

  def test_should_disable_an_invalid_ldap_setting
    # Given that
    ldap_setting = LdapSetting.find_by_auth_source_ldap_id(2)
    assert ldap_setting.active?

    # When we do
    get :disable, params: { id: ldap_setting.id }
    assert_redirected_to ldap_settings_path
    assert_match /success/, flash[:notice]

    # We should have
    ldap_setting = LdapSetting.find_by_auth_source_ldap_id(2)
    assert_nil ldap_setting.member_group, 'LdapSetting is not the same'
    assert !ldap_setting.active?, "LdapSetting must be disabled"
  end

  def test_should_enable_ldap_setting
    # Given that
    @ldap_setting.active = false; @ldap_setting.save
    ldap_setting = LdapSetting.find_by_auth_source_ldap_id(@ldap_setting.id)
    assert !ldap_setting.active?, "LdapSetting must be disabled"
    assert_equal 'member', ldap_setting.member_group

    # When we do
    get :enable, params: { id: ldap_setting.id }
    assert_redirected_to ldap_settings_path
    assert_match /success/, flash[:notice]

    # We should have
    ldap_setting = LdapSetting.find_by_auth_source_ldap_id(ldap_setting.id)
    assert_equal 'member', ldap_setting.member_group, 'LdapSetting is not the same'
    assert ldap_setting.active?, "LdapSetting must be enabled"
  end

  def test_should_not_enable_ldap_setting_with_errors
    # Given that
    @ldap_setting.active = false; @ldap_setting.save
    @ldap_setting.send(:attribute=, :dyngroups, 'invalid')
    @ldap_setting.send(:settings=, @ldap_setting.send(:attributes))

    @ldap_setting = LdapSetting.find_by_auth_source_ldap_id(@ldap_setting.id)
    assert !@ldap_setting.active?, 'LdapSetting must be disabled'
    assert_equal 'member', @ldap_setting.member_group

    # When we do
    get :enable, params: { id: @ldap_setting.id }
    assert_redirected_to ldap_settings_path
    assert_match /invalid settings/, flash[:error]

    # We should have
    ldap_setting = LdapSetting.find_by_auth_source_ldap_id(@ldap_setting.id)
    assert_equal 'member', ldap_setting.member_group, 'LdapSetting is not the same'
    assert !ldap_setting.active?, "LdapSetting must be disabled"
  end

  def test_should_fail_with_error
    put :update, params: { 
      id: @ldap_setting.id, 
      ldap_setting: {
        auth_source_ldap_id: @auth_source_id,
        active: true,
        groupname: 'cn',
        groups_base_dn: 'groups_base_dn',
        class_group: 'group',
        class_user: nil,                     # Missing required field
        group_membership: 'on_members',
        groupid: 'groupid',
        nested_groups: '',
        user_groups: 'memberof',
        sync_on_login: '',
        dyngroups: ''
      } 
    }
    assert @controller.view_assigns['ldap_setting'].errors.of_kind?(:class_user, :blank),
           'An error must be reported for :class_user'
    assert_response :success
  end

  def test_should_update_ldap_setting
    put :update, params: { 
      id: @ldap_setting.id, 
      ldap_setting: {
        auth_source_ldap_id: @auth_source_id,
        active: true,
        account_disabled_test: '',
        account_flags: '',
        attributes_to_sync: '',
        class_group: 'group',
        class_user: 'user',
        create_groups: '',
        create_users: '',
        fixed_group: '',
        group_memberid: '',
        group_membership: 'on_members',
        group_parentid: '',
        group_search_filter: '',
        groupid: 'groupid',
        groupname: 'cn',
        groupname_pattern: '',
        groups_base_dn: 'groups_base_dn',
        member: '',
        member_group: '',
        nested_groups: '',
        parent_group: '',
        required_group: '',
        user_fields_to_sync: [],
        group_fields_to_sync: [],
        user_ldap_attrs: {},
        group_ldap_attrs: {},
        user_groups: 'memberof',
        user_memberid: '',
        sync_on_login: '',
        dyngroups: ''
      }
    }
    assert_redirected_to ldap_settings_path
    # Assert on the persisted outcome rather than the controller's ivar
    assert LdapSetting.find_by_auth_source_ldap_id(@ldap_setting.id).valid?
    assert_match /success/, flash[:notice]
  end

  # v2.6 replaced the text/plain dump this used to assert (and the nested
  # ldap_test[test_users] params) with a rendered HTML fragment driven by flat
  # test_users / test_groups params. Rewritten against that interface.
  def test_should_test
    put :test, params: {
      id: @ldap_setting.id,
      ldap_setting: @ldap_setting.send(:attributes),
      test_users: 'example1',
      test_groups: 'Therß'
    }

    assert_response :success
    assert_equal 'text/html', response.media_type

    # The entity under test is named, and its field-level diff table rendered
    assert_match 'example1', response.body
    assert_match 'Therß', response.body
    assert_select 'table.ldap-diff'
    assert_select 'span.ldap-verdict'

    assert_no_match /ldap_test\.rb/, response.body, 'Should not throw an error'
  end

  # The all_users / all_groups listings are a separate branch of _test_result and
  # were previously uncovered — nothing rendered their bucket lists or the entity
  # links inside them.
  def test_should_test_all_users
    put :test, params: {
      id: @ldap_setting.id,
      ldap_setting: @ldap_setting.send(:attributes),
      test_case: 'all_users'
    }

    assert_response :success
    assert_select 'div.ldap-test-bucket'
    assert_select 'a.ldap-test-entity'
    assert_no_match /ldap_test\.rb/, response.body, 'Should not throw an error'
  end

  def test_should_test_all_groups
    put :test, params: {
      id: @ldap_setting.id,
      ldap_setting: @ldap_setting.send(:attributes),
      test_case: 'all_groups'
    }

    assert_response :success
    assert_select 'div.ldap-test-bucket'
    assert_select 'a.ldap-test-entity'
    assert_no_match /ldap_test\.rb/, response.body, 'Should not throw an error'
  end

  def test_should_validate_on_test
    @ldap_setting.dyngroups = 'invalid'

    put :test, params: {
      id: @ldap_setting.id,
      ldap_setting: @ldap_setting.send(:attributes),
      test_users: 'example1',
      test_groups: 'Therß'
    }

    assert_response :success

    # Renders the ldap_setting_invalid partial instead of running the test.
    # (The old regex wanted a space before "Dynamic groups" — an artifact of the
    # plain-text indentation; the message is now a list item.)
    assert_match /Validation errors/, response.body
    assert_select 'li', /Dynamic groups/

    assert_no_match /ldap_test\.rb/, response.body, 'Should not throw an error'
  end
end