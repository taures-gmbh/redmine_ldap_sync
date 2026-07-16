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
class LdapSettingsController < ApplicationController
  layout 'admin'
  self.main_menu = false
  menu_item :ldap_sync

  before_action :require_admin
  before_action :find_ldap_setting, :only => [:show, :edit, :update, :test, :apply_user, :apply_group, :enable, :disable]
  before_action :update_ldap_setting_from_params, :only => [:edit, :update, :test]

  if respond_to? :skip_before_action
    skip_before_action :verify_authenticity_token, :if => :js_request?
  end

  # GET /ldap_settings
  def index
    @ldap_settings = LdapSetting.all

    # With a single LDAP source the list is a pointless hop — go straight to it
    if @ldap_settings.size == 1
      redirect_to edit_ldap_setting_path(@ldap_settings.first)
      return
    end

    respond_to do |format|
      format.html # index.html.erb
    end
  end

  # GET /ldap_settings/base_settings.js
  def base_settings
    respond_to do |format|
      format.js # base_settings.js.erb
    end
  end

  # GET /ldap_settings/1
  def show
    redirect_to edit_ldap_setting_path(@ldap_setting)
  end

  # GET /ldap_settings/1/edit
  def edit
    respond_to do |format|
      format.html # edit.html.erb
    end
  end

  # PUT /ldap_settings/1/disable
  def disable
    @ldap_setting.disable!

    flash[:notice] = l(:text_ldap_setting_successfully_updated); redirect_to_referer_or ldap_settings_path
  end

  # PUT /ldap_settings/1/enable
  def enable
    @ldap_setting.active = true

    respond_to do |format|
      if @ldap_setting.save
        format.html { flash[:notice] = l(:text_ldap_setting_successfully_updated); redirect_to_referer_or ldap_settings_path }
      else
        format.html { flash[:error] = l(:error_cannot_enable_with_invalid_settings); redirect_to_referer_or ldap_settings_path }
      end
    end
  end

  # PUT /ldap_settings/1/test
  def test
    return render :partial => 'ldap_setting_invalid' unless @ldap_setting.valid?

    users = params[:test_users].to_s.split(',').map(&:strip).reject(&:blank?)
    groups = params[:test_groups].to_s.split(',').map(&:strip).reject(&:blank?)
    @test_case = %w(all_users all_groups).include?(params[:test_case]) ? params[:test_case] : 'entities'

    # LdapTest.new forces the (in-memory) setting active for the test bind, so
    # capture the real state first — it gates the apply button
    @sync_active = @ldap_setting.active?
    @test = LdapTest.new(@ldap_setting)

    if @test.valid?
      case @test_case
      when 'all_users' then @test.run_all_users
      when 'all_groups' then @test.run_all_groups
      else @test.run_with_users_and_groups(users, groups)
      end
      render :partial => 'test_result'
    else
      render :partial => 'ldap_test_invalid'
    end
  end

  # PUT /ldap_settings/1/apply_user
  # Runs the plugin's real per-user sync for a single login — creating the
  # user when missing, exactly like a full sync run — then re-runs the test
  # for it to show the new state.
  def apply_user
    auth_source = @ldap_setting.auth_source_ldap
    login = params[:login].to_s
    user = ::User.where("LOWER(login) = ?", login.mb_chars.downcase.to_s).first

    if !@ldap_setting.active? || (user.present? && user.auth_source_id != auth_source.id)
      render :partial => 'ldap_apply_invalid'
      return
    end

    auth_source.sync_single_user(login)

    @applied = :user
    @test_case = 'entities'
    @sync_active = true
    @test = LdapTest.new(@ldap_setting)
    @test.run_with_users_and_groups([login], [])

    # If the re-test does not come back in sync, part of the sync failed
    # (e.g. mail address already taken) — warn instead of claiming success
    data = @test.users_at_ldap[login]
    @apply_incomplete = !(data.is_a?(Hash) && data[:verdict] == :in_sync)
    render :partial => 'test_result'
  end

  # PUT /ldap_settings/1/apply_group
  # Applies a group's member delta by running the real per-user sync for every
  # user behind an added/removed row — creating missing users like a full sync
  # run would — then re-runs the group test to show the new state.
  def apply_group
    name = params[:group].to_s

    unless @ldap_setting.active?
      render :partial => 'ldap_apply_invalid'
      return
    end

    auth_source = @ldap_setting.auth_source_ldap
    # recompute the delta server-side — never trust the client's view of it
    diff = LdapTest.new(@ldap_setting)
    diff.run_with_users_and_groups([], [name])
    data = diff.groups_at_ldap[name]

    if !data.is_a?(Hash) || !data[:matches_pattern]
      render :partial => 'ldap_apply_invalid'
      return
    end

    logins = data[:member_rows].
      select {|row| [:added, :removed].include?(row[:status]) }.
      map {|row| row[:name] }

    # one bound connection for the whole batch (sync_single_user reuses it)
    auth_source.send(:with_ldap_connection) do |_|
      logins.each {|login| auth_source.sync_single_user(login) }
    end

    @applied = :group
    @test_case = 'entities'
    @sync_active = true
    @test = LdapTest.new(@ldap_setting)
    @test.run_with_users_and_groups([], [name])

    re_test = @test.groups_at_ldap[name]
    @apply_incomplete = !(re_test.is_a?(Hash) &&
      re_test[:member_rows].none? {|row| [:added, :removed].include?(row[:status]) })
    render :partial => 'test_result'
  end

  # PUT /ldap_settings/1
  def update
    respond_to do |format|
      if @ldap_setting.save
        format.html { flash[:notice] = l(:text_ldap_setting_successfully_updated); redirect_to_referer_or ldap_settings_path }
      else
        format.html { render 'edit' }
      end
    end
  end

  private

    def js_request?
      request.format.js?
    end

    def update_ldap_setting_from_params
      %w(user group).each do |e|
        params[:ldap_setting]["#{e}_fields_to_sync"] = params["#{e}_fields_to_sync"]
        params[:ldap_setting]["#{e}_ldap_attrs"] = params["#{e}_ldap_attrs"]
      end if params[:ldap_setting]
      @ldap_setting.safe_attributes = params[:ldap_setting] if params[:ldap_setting]
    end

    def find_ldap_setting
      @ldap_setting = LdapSetting.find_by_auth_source_ldap_id(params[:id])
      render_404 if @ldap_setting.nil?
    end
end
