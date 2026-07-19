Redmine LDAP Sync
=================

Extends Redmine's built-in LDAP authentication with **user and group
synchronization** — on login and via rake tasks — plus an interactive
LDAP↔Redmine inspection tool built into the settings page.

This is the **taures-gmbh** maintained fork. It descends from
[thorin/redmine_ldap_sync][thorin] (unmaintained) by way of the community
forks, and is actively kept working on current Redmine.

**Tested on:** Redmine 6.1.x / Rails 7.x / Ruby 3.x. Requires Redmine **5.0.0
or higher** (`requires_redmine`). Older Redmine/Ruby lines are covered by the
plugin's compatibility shims but are no longer the primary target.

Current version: **2.7.1** — see [What's new](#whats-new-in-this-fork).

Features
--------

 * Synchronization of user fields and group memberships **on login** and via
   rake tasks.
 * Detects and disables users that have been removed from LDAP.
 * Detects and disables users flagged as disabled on Active Directory
   (see [MS KB Article 305144][uacf]).
 * Detects and includes **nested groups**; nested membership is served from an
   on-disk cache that the rake task refreshes.
 * Optional **dynamic groups** support (OpenLDAP `slapo-dynlist`).
 * An interactive **Test** tab that inspects the live LDAP↔Redmine state for a
   single user or group — or all of them — with diffs, and can apply changes
   per entity.

**Remarks:**

 * Intended to run against any LDAP directory, but only verified against
   **Active Directory** and **OpenLDAP (slapd)**.
 * A user is only removed from groups that *exist on LDAP*, so LDAP and
   non-LDAP groups can coexist.
 * Groups deleted on LDAP are **not** deleted on Redmine.

What's new in this fork
-----------------------

Recent releases turned the admin page from a form-plus-text-dump into a
tabbed, self-explaining tool. Highlights:

* **Redmine 6.x compatibility** — the `SortedSet` dependency was dropped so the
  plugin installs cleanly on the official Redmine Docker image (no extra gems;
  the `Gemfile` is intentionally empty).
* **Tabbed settings page** (v2.7.0) — *Settings* and *Test* are two
  deep-linkable tabs (`?tab=test`). When only one LDAP source exists the server
  list is skipped and you land straight on the settings, titled like a core
  admin page with an active/disabled badge.
* **Lock detection as one explicit group** — lock-state attribute and condition
  sit side by side, with an examples table for common directory services, and
  are mirrored live onto the Test tab.
* **Interactive sync test** (v2.6.0) — the Test tab is a full inspection tool:
  - *Single user*: a field-level diff table (field · Redmine current · LDAP
    new · status), full group-membership picture with presence marks, a sync
    verdict badge, the Redmine account state, and the raw LDAP attributes
    behind a toggle. Users excluded by the user filter are distinguished from
    ones that don't exist.
  - *Single group*: a member diff between the Redmine group and the LDAP group
    (added / removed / unchanged / not managed / outside the user filter), a
    group-state badge and a name-pattern verdict.
  - *All users* / *All groups*: a full status listing bucketed by sync outcome;
    every name links back to the single-entity test.
  - **Apply** buttons run the real per-user sync (creating missing users just
    like a scheduled run would), then re-test and report honestly.
* **Live evaluation of unsaved settings** — the test evaluates the settings
  currently in the form on every run, so you can dial in filters and the lock
  condition before saving. Press **Enter** in the test form to run it.
* **Complete German translation** and edit-page usability polish (field hints,
  a test explainer, aligned forms).

Installation & upgrade
-----------------------

### Install / upgrade

1. **Install** — clone into `#{RAILS_ROOT}/plugins`:
   ```
   cd #{RAILS_ROOT}/plugins
   git clone https://github.com/taures-gmbh/redmine_ldap_sync.git
   ```
   **Upgrade** — from inside the plugin directory, `git pull`.

2. Install gems (from the Redmine root):
   ```
   bundle install
   ```

3. Migrate the database (back it up first):
   ```
   bundle exec rake redmine:plugins:migrate RAILS_ENV=production
   ```

4. Confirm the rake tasks are registered:
   ```
   bundle exec rake -T redmine:plugins:ldap_sync RAILS_ENV=production
   ```
   You should see the [rake tasks](#rake-tasks) listed.

5. Restart Redmine. **Redmine LDAP Sync** now appears under
   *Administration → Plugins*.

### Uninstall

1. Downgrade the database (back it up first):
   ```
   bundle exec rake redmine:plugins:migrate NAME=redmine_ldap_sync VERSION=0 RAILS_ENV=production
   ```
2. Remove the plugin directory from `#{RAILS_ROOT}/plugins`.
3. Restart Redmine.

Usage
-----

### Configuration

Open **Administration → LDAP synchronization**. The plugin binds to an existing
Redmine LDAP authentication source; configure the connection under
*Administration → LDAP authentication* first.

**LDAP schema & connection:**

+ **Base settings** — preloads the configuration with predefined values for a
  known directory type (loaded from `config/base_settings.yml`).
+ **Group base DN** — where groups live, e.g. `ou=people,dc=example,dc=com`.
+ **Groups / Users objectclass** — the object classes to match.
+ **Users search scope** — *One level* (immediate children of the user base DN)
  or *Whole subtree*.
+ **Group name pattern** — (optional) a regexp the group name must match to be
  imported, e.g. `\.team$`.
+ **Group search filter** — (optional) an LDAP filter applied when searching
  for groups.
+ **Group membership** — how membership is determined:
  - *On the group class*: from the users listed on the group.
  - *On the user class*: from the groups listed on the user.
+ **Enable nested groups** — look up parent groups recursively:
  - *Membership on the parent class* / *on the member class*.

**Lock detection:**

+ **Account flags attribute (user)** — the LDAP attribute holding the disabled
  flag, e.g. `userAccountControl`.
+ **Account disabled test** — a Ruby boolean expression over the `flags`
  variable that returns `true` when the account is disabled, e.g.
  `flags.to_i & 2 != 0` or `flags.include? 'D'`.

**LDAP attributes** (which apply depends on the membership/nesting mode):

+ **Group name (group)** — attribute for the group name, e.g. `sAMAccountName`.
+ **Primary group (user)** — attribute identifying the user's primary group
  (also used as the group id when searching), e.g. `gidNumber`.
+ **Members (group)** / **Memberid (user)** — for *membership on the group
  class*; the memberid must match the members attribute (e.g. `member` / `dn`).
+ **Groups (user)** / **Groupid (group)** — for *membership on the user class*
  (e.g. `memberof` / `distinguishedName`).
+ **Member groups (group)** / **Memberid attribute (group)** — for nested
  *membership on the parent class*.
+ **Parent groups (group)** / **Parentid attribute (group)** — for nested
  *membership on the member class*.

**Synchronization actions:**

+ **Users must be members of** — (optional) a group a user must belong to for
  Redmine access.
+ **Administrators group** — (optional) members become Redmine administrators.
+ **Add users to group** — (optional) a Redmine-only group every LDAP-created
  user is added to on creation.
+ **Create new groups / users** — create Redmine entities that don't yet exist.
+ **Synchronize on login**:
  - *User fields and groups*: sync both; lock/deny users disabled on LDAP or
    removed from the *must be member of* group.
  - *User fields*: sync fields only; lock only on LDAP-disabled, not on group
    changes.
  - *Disabled*: no on-login sync.
+ **Dynamic groups** — *Enabled*, *Enabled with a ttl* (cache expires every
  **t** minutes), or *Disabled*. See [note ¹](#notes).
+ **User/Group field mapping** — per field: whether to synchronize it, which
  LDAP attribute to read, and the default value.

### The Test tab

Use *Administration → LDAP synchronization → Test* to dry-inspect what a sync
would do **against the settings currently in the form** (no save required):
pick *Single user*, *Single group*, *All users* or *All groups*, run the test
(Enter works), read the diff, and optionally **Apply** to run the real per-user
sync for that entity.

### Rake tasks

```
# bundle exec rake -T redmine:plugins:ldap_sync
rake redmine:plugins:ldap_sync:sync_all     # Synchronize both users and groups with LDAP
rake redmine:plugins:ldap_sync:sync_groups  # Synchronize groups' fields with those on LDAP
rake redmine:plugins:ldap_sync:sync_users   # Synchronize users' fields and groups with those on LDAP
```

Use these for periodic synchronization, e.g. every 60 minutes:

```
35 * * * *   www-data /usr/bin/rake -f /opt/redmine/Rakefile --silent redmine:plugins:ldap_sync:sync_users RAILS_ENV=production 2>&- 1>&-
```

The tasks honor three environment variables:

+ **DRY_RUN** — run without changing the database.
+ **ACTIVATE_USERS** — activate users that are active on LDAP.
+ **LOG_LEVEL** — verbosity: `silent`, `error`, `change`, or `debug` (default).

### Base settings

Base settings are loaded from `config/base_settings.yml`. They are provided as a
convenience and may need adjusting for your directory — improvements welcome.

Running the tests
-----------------

See [`doc/RUNNING_TESTS`](doc/RUNNING_TESTS). In short:

```
NAME=redmine_ldap_sync bundle exec rake redmine:plugins:test
```

The tests need a local slapd loaded with `test/fixtures/ldap/test-ldap.ldif`
(setup instructions in that doc).

Contributing
------------

Issues and pull requests are welcome at
<https://github.com/taures-gmbh/redmine_ldap_sync>.

License
-------

Released under the **GPL v3**. See [LICENSE](LICENSE).

Notes
-----

1. On dynamic groups see [OpenLDAP Overlays — Dynamic Lists][overlays-dynlist]
   and [slapo-dynlist(5)][slapo-dynlist]. Resolving a user's dynamic groups is
   costly, so a cache stores the dynamic-group↔user relationship; the rake task
   refreshes it.

[thorin]: https://github.com/thorin/redmine_ldap_sync
[uacf]: http://support.microsoft.com/kb/305144
[overlays-dynlist]: http://www.openldap.org/doc/admin24/overlays.html#Dynamic%20Lists
[slapo-dynlist]: http://www.openldap.org/software/man.cgi?query=slapo-dynlist
