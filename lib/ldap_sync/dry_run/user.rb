# encoding: utf-8
module LdapSync::DryRun::User
  module ClassMethods
    def create(attributes)
      user = User.new(attributes)
      user.email_address ||= DryRunEmailAddress.new
      user.groups = DryRunGroupsProxy.new(user)
      yield user if block_given?
      user
    end
  end

  module InstanceMethods
    def lock!; end
    def activate!; end
    def update_attributes(attrs = {}); end
    def save(*args); end
  end

  class DryRunEmailAddress
    include ActiveModel::Model
    attr_accessor :address
  end

  class DryRunGroupsProxy < Array
    def initialize(user)
      @user = user
      super()
    end

    def <<(groups)
      names = Array(groups).map(&:lastname)
      puts "   !! Added to groups '#{names.join("', '")}'" unless names.empty?
      super(groups)
    end

    def delete(*groups)
      names = Array(groups).map(&:lastname)
      puts "   !! Removed from groups '#{names.join("', '")}'" unless names.empty?
      super(*groups)
    end
  end

  def self.included(receiver)
    receiver.extend(ClassMethods)
    receiver.include(InstanceMethods)

    # vermijd dubbele HABTM-definities
    unless receiver.reflect_on_association(:groups)
      receiver.has_and_belongs_to_many :groups
    end
  end
end
