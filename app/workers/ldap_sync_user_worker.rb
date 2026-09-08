# frozen_string_literal: true

# Syncs one user's fields and groups from LDAP, out of band.
#
# LdapSync::Hooks enqueues this after a successful login instead of binding
# inline, because a real bind against the directory measured ~480 ms and that
# lands squarely on the login request. The user is already authenticated by the
# time this runs; the sync only refreshes fields, groups and account status, so
# a second or two of lag is fine. LdapSyncAllWorker remains the backstop if
# Sidekiq is down or the job is dropped.
class LdapSyncUserWorker
  include Sidekiq::Worker

  sidekiq_options(
    queue: 'default',
    retry: 2,
    # Deduplicated on the argument, so a user who reloads the login page a few
    # times in a row still causes a single bind.
    lock: :until_executed,
    lock_ttl: 300,
    on_conflict: :log
  )

  def perform(user_id)
    # Settings are only invalidated per web request (ApplicationController);
    # without this, the long-lived Sidekiq process syncs with boot-time settings.
    Setting.check_cache

    user = User.find_by(id: user_id)
    return unless user&.sync_on_login?

    source = user.auth_source
    # A '$login' account template binds as the user, which needs a password we
    # do not have here. Those setups are left to LdapSyncAllWorker.
    return if source.nil? || source.connect_as_user?

    source.sync_user(user, false, :try_to_login => true)
  rescue StandardError => e
    # Let Sidekiq retry, but say which user it was.
    Rails.logger.error("ldap_sync: on-login sync failed for user #{user_id}: #{e.class}: #{e.message}")
    raise
  end
end
