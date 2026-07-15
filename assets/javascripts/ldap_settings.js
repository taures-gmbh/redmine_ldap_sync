/*
 * Copyright (C) 2011-2013  The Redmine LDAP Sync Authors
 *
 * This file is part of Redmine LDAP Sync.
 *
 * Redmine LDAP Sync is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Redmine LDAP Sync is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Redmine LDAP Sync.  If not, see <http://www.gnu.org/licenses/>.
 */
$(function() {
  "use strict";

  function show_options(elem, ambit) {
    var selected = $(elem).val();
    var prefix = '#ldap_attributes div.' + ambit;

    $(prefix).hide();

    // Remove required for hidden elements
    $(prefix + ' input').removeAttr('required');

    if (selected !== '') {
      $(prefix + '.' + selected).show();
      
      // Add required for visible and required inputs
      $(prefix + '.' + selected + ' input').each(function(){

        if($('label[for="' + this.id + '"]').hasClass('required'))
          $(this).attr('required', 'required');

      });
    }
  }

  function show_dyngroups_ttl(elem) {
    if ($(elem).val() == 'enabled_with_ttl')
      $('#dyngroups-cache-ttl').show();
    else
      $('#dyngroups-cache-ttl').hide();
  }

  show_options($('#ldap_setting_group_membership'), 'membership');
  $('#ldap_setting_group_membership')
    .bind('change keyup', function() { show_options(this, 'membership'); });

  show_options($('#ldap_setting_nested_groups'), 'nested');
  $('#ldap_setting_nested_groups')
    .bind('change keyup', function() { show_options(this, 'nested'); });

  $('#base_settings').bind('change keyup', function() {
    var id = $(this).val();
    if (!base_settings[id]) return;

    var hash = base_settings[id];
    for (var k in hash) if (hash.hasOwnProperty(k)) {
      if (k === 'name' || hash[k] === $('#ldap_setting_' + k).val()) continue;

      $('#ldap_setting_' + k).val(hash[k]).change()
        .effect('highlight', {easing: 'easeInExpo'}, 500);
    }
  });

  show_dyngroups_ttl($('#ldap_setting_dyngroups'));
  $('#ldap_setting_dyngroups')
    .bind('change keyup', function() { show_dyngroups_ttl(this); });

  $('input[name^="ldap_test"]').keydown(function (e) {
    if (e.which == 13) {
      $('#commit-test').click();
      e.preventDefault();
    }
  });

  $('form[id^="edit_ldap_setting"]').submit(function() {
    var current_tab = $('a[id^="tab-"].selected').attr('id').substring(4);
    $('form[id^="edit_ldap_setting"]').append(
      '<input type="hidden" name="tab" value="' + current_tab + '">'
    );
  });

  //$('#commit-test')
  //  .bind('ajax:before', function() {
  //    var data = $('form[id^="edit_ldap_setting"]').serialize();
  //    $(this).data('params', data);
  //  })
  //  .bind('ajax:success', function(event, data) {
  //    $('#test-result').text(data);
  //  });

  var runLdapTest = function(testCase) {
    var form = $('form[id^="commit-test"]');
    var result = $('#test-result');
    var buttons = $('.commit-test-button');
    // form.serialize() never includes buttons — append the clicked button's
    // test case explicitly ("Ausführen" carries none = specific entities)
    var data = form.serialize();
    if (testCase) data += '&test_case=' + encodeURIComponent(testCase);

    $.ajax({
      url : form.attr('action'),
      type: form.attr('method'),
      data: data,
      // keep Redmine's global ajax indicator out of it; the result box
      // carries its own loading state, right where the user is looking
      global: false,
      beforeSend: function() {
        buttons.prop('disabled', true);
        result.text(result.data('loading') || 'Loading...');
        result[0].scrollIntoView({behavior: 'smooth', block: 'nearest'});
      },
      complete: function() {
        buttons.prop('disabled', false);
      },
      success: function (data) {
        // server renders an escaped HTML partial for every test case
        result.html(data);
      },
      error: function(){
        result.text(result.data('error') || 'The test request failed.');
      }
    });
  };

  $(".commit-test-button").on('click', function(event){
    //cancel submit_tag
    event.preventDefault();
    runLdapTest($(this).data('test-case'));
  });

  // drill-down: a name in an all-users/all-groups listing runs the
  // single-entity test for it, as if typed into the field + Ausführen
  $('#test-result').on('click', 'a.ldap-test-entity', function(event){
    event.preventDefault();
    var name = $(this).data('name');
    if ($(this).data('type') === 'user') {
      $('#test_users').val(name);
      $('#test_groups').val('');
    } else {
      $('#test_groups').val(name);
      $('#test_users').val('');
    }
    runLdapTest();
  });

  // apply: run the real sync (single user, or all changed members of a
  // group), then show the re-tested (new) state
  $('#test-result').on('click', 'button.ldap-apply-button', function(event){
    event.preventDefault();
    var btn = $(this);
    if (!window.confirm(btn.data('confirm'))) return;

    var payload = {};
    if (btn.data('login')) payload.login = btn.data('login');
    if (btn.data('group')) payload.group = btn.data('group');

    var result = $('#test-result');
    $.ajax({
      url: btn.data('url'),
      type: 'PUT',
      data: payload,
      global: false,
      beforeSend: function() {
        result.text(result.data('loading') || 'Loading...');
      },
      success: function (data) {
        result.html(data);
      },
      error: function(){
        result.text(result.data('error') || 'The test request failed.');
      }
    });
  });
});