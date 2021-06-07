require 'redmine'

Redmine::Plugin.register :redmine_ldap_sync do
  name 'Redmine LDAP Sync'
  author 'Akinori Iwasaki, DevOps-TauRes, Ricardo Santos, Taine Woo'
  author_url 'https://github.com/aki360p'
  description 'Syncs users and groups with ldap'
  url 'https://github.com/aki360p/redmine_ldap_sync'
  version '2.3.0dev'
  requires_redmine :version_or_higher => '4.0.0'

  settings :default => HashWithIndifferentAccess.new()
  menu :admin_menu, :ldap_sync, { :controller => 'ldap_settings', :action => 'index' }, :caption => :label_ldap_synchronization,
                    :html => {:class => 'icon icon-ldap-sync'}
end

Rails.application.config.to_prepare do
  require_dependency 'ldap_sync/core_ext'
  require_dependency 'ldap_sync/infectors'
end

# hooks
require_dependency 'ldap_sync/hooks'
