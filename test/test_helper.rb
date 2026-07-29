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

# Opt-in: COVERAGE=1 writes a report to coverage/. Off by default so a plain
# test run neither needs simplecov nor writes into the working tree.
if ENV['COVERAGE']
  require 'simplecov'

  SimpleCov.start do
    add_group 'Controllers', 'app/controllers'
    add_group 'Models', 'app/models'
    add_group 'Helpers', 'app/helpers'
    add_group 'Libraries', 'lib'
    add_filter '/test/'
    add_filter 'init.rb'
    root File.expand_path(File.dirname(__FILE__) + '/../')
  end
end

require File.expand_path(File.dirname(__FILE__) + '/../../../test/test_helper')

Rails.backtrace_cleaner.remove_silencers!

FIXTURE_PATH = File.expand_path(File.dirname(__FILE__) + '/fixtures')

# Point the fixture machinery at the plugin's own fixtures, REPLACING Redmine
# core's: the plugin ships its own users/groups/custom_fields, and loading both
# sets collides on ids.
#
# Rails 7.1 deprecated the singular fixture_path in favour of the fixture_paths
# array and Rails 7.2 removed it, so which one to use depends on the Redmine
# under test (5.1 is on Rails 6.1, 6.x on 7.2, 7.0 on 8.0).
def self.use_plugin_fixtures(klass)
  if klass.respond_to?(:fixture_paths=)
    klass.fixture_paths = [FIXTURE_PATH]
  else
    klass.fixture_path = FIXTURE_PATH
  end

  # Redmine core's test_helper declares `fixtures :all`, which is expanded to
  # concrete table names immediately — against core's fixture path, before the
  # assignment above takes effect. Clear that expansion and redo it against ours.
  klass.fixture_table_names = []
  klass.fixtures :all
end

class ActiveSupport::TestCase
  # Two kinds of process-wide state leak between tests and made the suite
  # order-dependent (up to 18 failures depending on the seed):
  #
  # * Redmine's Setting cache. LdapSetting lives in Setting.plugin_redmine_ldap_sync,
  #   and a test that mutates it leaves the cache holding the mutated value after
  #   its transaction rolls back — the DB's max(updated_on) moves backwards, so
  #   check_cache does not invalidate. The next test then validates against
  #   settings that do not match the fixtures.
  # * AuthSourceLdap's class attributes, which no transaction rolls back.
  setup do
    Setting.clear_cache
    AuthSourceLdap.running_rake = false
    AuthSourceLdap.activate_users = false
    AuthSourceLdap.dyngroups_updated = false
    AuthSourceLdap.trace_level = :debug
  end

  def clear_ldap_cache!
    FileUtils.rm_rf Rails.root.join("tmp/ldap_cache")
  end
end

use_plugin_fixtures(ActiveSupport::TestCase)
use_plugin_fixtures(ActionDispatch::IntegrationTest)

module ActionController::TestCase::Behavior
  def process_patched(action, method, *args)
    options = args.extract_options!
    if options.present?
      params = options.delete(:params)
      options = options.merge(params) if params.present?
      args << options
    end
    process_unpatched(action, method, *args)
  end

  if Rails::VERSION::MAJOR < 5
    alias_method :process_unpatched, :process
    alias_method :process, :process_patched
  end
end