require 'redmine'

Redmine::Plugin.register :redmine_ldap_sync do
  name 'Redmine LDAP Sync'
  author 'Akinori Iwasaki, DevOps-TauRes, Ricardo Santos, Taine Woo, Tilman Klaeger'
  author_url 'https://github.com/aki360p'
  description 'Syncs users and groups with ldap'
  url 'https://github.com/aki360p/redmine_ldap_sync'
  version '2.3.1'
  requires_redmine :version_or_higher => '5.0.0'

  settings :default => HashWithIndifferentAccess.new()
  menu :admin_menu, :ldap_sync, { :controller => 'ldap_settings', :action => 'index' }, :caption => :label_ldap_synchronization,
                    :html => {:class => 'icon icon-ldap-sync'}
end


require File.expand_path('lib/ldap_sync/core_ext.rb', __dir__)
require File.expand_path('lib/ldap_sync/infectors.rb', __dir__)

# hooks
require File.expand_path('lib/ldap_sync/hooks.rb', __dir__)
