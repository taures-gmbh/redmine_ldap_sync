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

# On-login synchronization, end to end through a browser. These drive Redmine's
# own login and registration pages, so unlike the settings-page tests they are
# unaffected by this plugin's UI.
class LdapSync::LoginTest < LdapSync::UiTestCase
  def test_login_with_existing_user
    login_as 'loadgeek'

    assert_current_path '/my/page', :ignore_query => true
  end

  def test_login_should_create_the_user_on_the_fly
    assert_nil User.find_by_login('systemhack')

    login_as 'systemhack'

    assert_current_path '/my/page', :ignore_query => true
    user = User.find_by_login('systemhack')
    assert user, 'the user should have been created from LDAP'
    assert_equal 'Darryl', user.firstname
  end

  def test_login_with_a_user_incomplete_on_ldap_should_ask_for_the_missing_fields
    assert_nil User.find_by_login('incomplete')

    login_as 'incomplete'

    # LDAP authenticates the user, but its entry has no mail and no first name,
    # so Redmine cannot save it and falls back to the registration form.
    assert_selector 'h2', :text => /Register/i
    assert_nil User.find_by_login('incomplete')

    fill_in 'user[firstname]', :with => 'Incomplete'
    fill_in 'user[lastname]',  :with => 'User'
    fill_in 'user[mail]',      :with => 'incomplete@fakemail.com'
    find('input[name=commit]').click

    assert_current_path '/my/account', :ignore_query => true
    user = User.find_by_login('incomplete')
    assert user, 'the user should exist after completing the form'
    assert_equal 'incomplete@fakemail.com', user.mail
  end

  private
    # Deliberately not Redmine's log_user: that asserts the browser lands on
    # /my/page, which is exactly what the incomplete-user case must not do.
    def login_as(login, password = 'password')
      visit '/login'
      within '#login-form form' do
        fill_in 'username', :with => login
        fill_in 'password', :with => password
        find('input[name=login]').click
      end
    end
end
