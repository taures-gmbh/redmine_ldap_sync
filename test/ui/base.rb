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
require File.expand_path(File.dirname(__FILE__) + '/../test_helper')
require File.expand_path(File.dirname(__FILE__) + '/../../../../test/application_system_test_case')

# Redmine's ApplicationSystemTestCase drives Chrome through Selenium and gives us
# log_user and wait_for_ajax. It expects google-chrome on PATH and lets Selenium
# Manager fetch a matching driver; the test container has Debian's chromium and no
# reason to reach the internet, so point Selenium at both when told where they are.
# (script/test-setup.sh WITH_BROWSER=1 installs them and exports these.)
Selenium::WebDriver::Chrome.path = ENV['CHROME_BIN'] if ENV['CHROME_BIN'].present?
if ENV['CHROMEDRIVER_BIN'].present?
  Selenium::WebDriver::Chrome::Service.driver_path = ENV['CHROMEDRIVER_BIN']
end

module LdapSync
  class UiTestCase < ApplicationSystemTestCase
    # ApplicationSystemTestCase#setup runs Setting.delete_all, which throws away
    # this plugin's whole configuration: an LdapSetting is stored inside
    # Setting.plugin_redmine_ldap_sync, not in a table of its own. Without putting
    # it back, every page renders an empty, disabled configuration.
    #
    # ActiveRecord::FixtureSet.create_fixtures is NOT a way to restore it: the
    # settings fixture is already in Rails' fixture cache, so the call returns the
    # cached set and inserts nothing — a silent no-op. Assign the value instead.
    LDAP_SETTINGS_FIXTURE =
      YAML.unsafe_load(
        YAML.unsafe_load(
          ERB.new(File.read(File.join(FIXTURE_PATH, 'settings.yml'))).result
        )['redmine_ldap_setting']['value']
      )

    setup do
      Setting.plugin_redmine_ldap_sync = LDAP_SETTINGS_FIXTURE
      Setting.clear_cache
    end

    private
      # The settings form is one page with two Redmine tabs; the test tab submits
      # over AJAX. Open it by URL rather than clicking, so a failure in the tab JS
      # cannot be mistaken for a failure in what the test is actually about.
      def visit_ldap_setting(id = 1, tab: nil)
        visit tab ? "/admin/ldap_sync/#{id}/edit?tab=#{tab}" : "/admin/ldap_sync/#{id}/edit"
      end
  end
end
