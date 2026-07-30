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

# Redmine stores firstname in a varchar(30) with a matching validation, so an LDAP
# name one character longer means the account is never created — silently, on every
# run. These cover the shortening that avoids that, and the fields it must leave
# alone.
class ShortenToFitTest < ActiveSupport::TestCase
  fixtures :auth_sources, :users, :settings, :custom_fields
  fixtures :email_addresses if Redmine::VERSION::MAJOR >= 3

  setup do
    @auth_source = auth_sources(:auth_sources_001)
    @limit = ::User.columns_hash['firstname'].limit
    assert_equal 30, @limit, 'the case these tests describe assumes varchar(30)'
  end

  test "a name that fits should be untouched" do
    assert_equal 'Erika', shorten('firstname', 'Erika')
  end

  test "a name one character over should lose only the last name to an initial" do
    # 31 characters: the shape of the case this was written for
    assert_equal 'Erika Charlotte Wilhelmine E.',
                 shorten('firstname', 'Erika Charlotte Wilhelmine Elke')
  end

  test "a longer name should keep abbreviating from the end until it fits" do
    result = shorten('firstname', 'Maximiliane Friederike Charlotte Wilhelmine Auguste')

    assert_operator result.length, :<=, @limit
    assert result.start_with?('Maximiliane'), "kept the leading name: #{result}"
    assert_equal 'Maximiliane F. C. W. A.', result
  end

  test "a single word too long has no space to abbreviate at and is cut" do
    result = shorten('firstname', 'A' * 40)

    assert_equal 30, result.length
    assert_equal 'A' * 30, result
  end

  test "lastname should be measured against its own wider column" do
    # lastname is varchar(255), so a name that firstname could not hold is fine here
    long = 'Erika Charlotte Wilhelmine Elke'

    assert_equal long, shorten('lastname', long)
    assert_operator ::User.columns_hash['lastname'].limit, :>, @limit
  end

  test "mail must never be shortened" do
    # A shortened address is a wrong address, not a shorter one. Better that the
    # save fails loudly than that the sync invents a plausible-looking mailbox.
    long_mail = "#{'a' * 40}@example.com"

    assert_equal long_mail, shorten('mail', long_mail)
  end

  test "a custom field value should not be shortened" do
    # custom values are text, not a users column, and have no limit to respect
    assert_equal 'x' * 60, shorten('42', 'x' * 60)
  end

  test "shortening should be reported in the sync log" do
    AuthSourceLdap.running_rake!
    AuthSourceLdap.trace_level = :change
    old_stdout, $stdout = $stdout, StringIO.new

    shorten('firstname', 'Erika Charlotte Wilhelmine Elke', 'e_muster')

    actual, $stdout = $stdout.string, old_stdout

    # Case-insensitive: trace downcases change-level lines, so the name is logged
    # lowercased. That is long-standing formatting — other tests rely on it for group
    # names — so the test bends, not the log.
    assert_match /shortened firstname/i, actual
    assert_match /erika charlotte wilhelmine e\./i, actual
    assert_include 'e_muster', actual, 'the affected login should be identifiable'
  end

  private
    def shorten(field, value, obj = nil)
      @auth_source.send(:shorten_to_fit, field, value, obj)
    end
end
