load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/common'

export IMAGE_NAME
IMAGE_NAME="${NAME}"

setup() {
  run_setup_file_if_necessary
}

setup_file() {
  local PRIVATE_CONFIG
  PRIVATE_CONFIG="$(duplicate_config_for_container . mail)"
  mv "${PRIVATE_CONFIG}/user-patches/user-patches.sh" "${PRIVATE_CONFIG}/user-patches.sh"
  docker run --rm -d --name mail \
		-v "${PRIVATE_CONFIG}":/tmp/docker-mailserver \
		-v "$(pwd)/test/test-files":/tmp/docker-mailserver-test:ro \
		-v "$(pwd)/test/onedir":/var/mail-state \
		-e ENABLE_CLAMAV=1 \
		-e SPOOF_PROTECTION=1 \
		-e ENABLE_SPAMASSASSIN=1 \
		-e REPORT_RECIPIENT=user1@localhost.localdomain \
		-e REPORT_SENDER=report1@mail.my-domain.com \
		-e SA_TAG=-5.0 \
		-e SA_TAG2=2.0 \
		-e SA_KILL=3.0 \
		-e SA_SPAM_SUBJECT="SPAM: " \
		-e VIRUSMAILS_DELETE_DELAY=7 \
		-e ENABLE_SRS=1 \
		-e SASL_PASSWD="external-domain.com username:password" \
		-e ENABLE_MANAGESIEVE=1 \
		--cap-add=SYS_PTRACE \
		-e PERMIT_DOCKER=host \
		-e DMS_DEBUG=0 \
		-h mail.my-domain.com -t "${NAME}"

  wait_for_finished_setup_in_container mail

  # generate accounts after container has been started
  docker run --rm -e MAIL_USER=added@localhost.localdomain -e MAIL_PASS=mypassword -t "${NAME}" /bin/sh -c 'echo "${MAIL_USER}|$(doveadm pw -s SHA512-CRYPT -u ${MAIL_USER} -p ${MAIL_PASS})"' >> "${PRIVATE_CONFIG}/postfix-accounts.cf"
  docker exec mail addmailuser pass@localhost.localdomain 'may be \a `p^a.*ssword'

  # setup sieve
	docker cp "${PRIVATE_CONFIG}/sieve/dovecot.sieve" mail:/var/mail/localhost.localdomain/user1/.dovecot.sieve

  # this relies on the checksum file beeing updated after all changes have been applied
  wait_for_changes_to_be_detected_in_container mail

	wait_for_smtp_port_in_container mail

  # wait for clamav to be fully setup or we will get errors on the log
  repeat_in_container_until_success_or_timeout 60 mail test -e /var/run/clamav/clamd.ctl

  # sending test mails
	docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/amavis-spam.txt"
	docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/amavis-virus.txt"
	docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/existing-alias-external.txt"
	docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/existing-alias-local.txt"
	docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/existing-alias-recipient-delimiter.txt"
	docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/existing-user1.txt"
	docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/existing-user2.txt"
	docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/existing-added.txt"
	docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/existing-user-and-cc-local-alias.txt"
	docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/existing-regexp-alias-external.txt"
	docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/existing-regexp-alias-local.txt"
	docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/existing-catchall-local.txt"
	docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/sieve-spam-folder.txt"
	docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/sieve-pipe.txt"
	docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/non-existing-user.txt"
	docker exec mail /bin/sh -c "sendmail root < /tmp/docker-mailserver-test/email-templates/root-email.txt"

  wait_for_empty_mail_queue_in_container mail
}

teardown() {
  run_teardown_file_if_necessary
}

teardown_file() {
  docker rm -f mail
}

# this test must come first to reliably identify when to run setup_file
@test "first" {
  skip 'Starting testing of letsencrypt SSL'
}

#
# configuration checks
#

@test "checking configuration: user-patches.sh executed" {
  run docker logs mail
  assert_output --partial "Default user-patches.sh successfully executed"
}

@test "checking configuration: hostname/domainname" {
  run docker run "${IMAGE_NAME:?}"
  assert_success
}

#
# processes
#

@test "checking process: postfix" {
  run docker exec mail /bin/bash -c "ps aux --forest | grep -v grep | grep '/usr/lib/postfix/sbin/master'"
  assert_success
}

@test "checking process: clamd" {
  run docker exec mail /bin/bash -c "ps aux --forest | grep -v grep | grep '/usr/sbin/clamd'"
  assert_success
}

@test "checking process: new" {
  run docker exec mail /bin/bash -c "ps aux --forest | grep -v grep | grep '/usr/sbin/amavisd-new'"
  assert_success
}

@test "checking process: opendkim" {
  run docker exec mail /bin/bash -c "ps aux --forest | grep -v grep | grep '/usr/sbin/opendkim'"
  assert_success
}

@test "checking process: opendmarc" {
  run docker exec mail /bin/bash -c "ps aux --forest | grep -v grep | grep '/usr/sbin/opendmarc'"
  assert_success
}

@test "checking process: fail2ban (disabled in default configuration)" {
  run docker exec mail /bin/bash -c "ps aux --forest | grep -v grep | grep '/usr/bin/python3 /usr/bin/fail2ban-server'"
  assert_failure
}

@test "checking process: fetchmail (disabled in default configuration)" {
  run docker exec mail /bin/bash -c "ps aux --forest | grep -v grep | grep '/usr/bin/fetchmail'"
  assert_failure
}

#
# imap
#

@test "checking process: dovecot imaplogin (enabled in default configuration)" {
  run docker exec mail /bin/bash -c "ps aux --forest | grep -v grep | grep '/usr/sbin/dovecot'"
  assert_success
}

@test "checking imap: server is ready with STARTTLS" {
  run docker exec mail /bin/bash -c "nc -w 2 0.0.0.0 143 | grep '* OK' | grep 'STARTTLS' | grep 'ready'"
  assert_success
}

@test "checking imap: authentication works" {
  run docker exec mail /bin/sh -c "nc -w 1 0.0.0.0 143 < /tmp/docker-mailserver-test/auth/imap-auth.txt"
  assert_success
}

@test "checking imap: added user authentication works" {
  run docker exec mail /bin/sh -c "nc -w 1 0.0.0.0 143 < /tmp/docker-mailserver-test/auth/added-imap-auth.txt"
  assert_success
}

#
# sasl
#

@test "checking sasl: doveadm auth test works with good password" {
  run docker exec mail /bin/sh -c "doveadm auth test -x service=smtp user2@otherdomain.tld mypassword | grep 'auth succeeded'"
  assert_success
}

@test "checking sasl: doveadm auth test fails with bad password" {
  run docker exec mail /bin/sh -c "doveadm auth test -x service=smtp user2@otherdomain.tld BADPASSWORD | grep 'auth failed'"
  assert_success
}

@test "checking sasl: sasl_passwd exists" {
  run docker exec mail [ -f /etc/postfix/sasl_passwd ]
  assert_success
}

#
# logs
#

@test "checking logs: mail related logs should be located in a subdirectory" {
  run docker exec mail /bin/sh -c "ls -1 /var/log/mail/ | grep -E 'clamav|freshclam|mail.log'|wc -l"
  assert_success
  assert_output 3
}

#
# smtp
#

@test "checking smtp: authentication works with good password (plain)" {
  run docker exec mail /bin/sh -c "nc -w 5 0.0.0.0 25 < /tmp/docker-mailserver-test/auth/smtp-auth-plain.txt | grep 'Authentication successful'"
  assert_success
}

@test "checking smtp: authentication fails with wrong password (plain)" {
  run docker exec mail /bin/sh -c "nc -w 20 0.0.0.0 25 < /tmp/docker-mailserver-test/auth/smtp-auth-plain-wrong.txt"
  assert_output --partial 'authentication failed'
  assert_success
}

@test "checking smtp: authentication works with good password (login)" {
  run docker exec mail /bin/sh -c "nc -w 5 0.0.0.0 25 < /tmp/docker-mailserver-test/auth/smtp-auth-login.txt | grep 'Authentication successful'"
  assert_success
}

@test "checking smtp: authentication fails with wrong password (login)" {
  run docker exec mail /bin/sh -c "nc -w 20 0.0.0.0 25 < /tmp/docker-mailserver-test/auth/smtp-auth-login-wrong.txt"
  assert_output --partial 'authentication failed'
  assert_success
}

@test "checking smtp: added user authentication works with good password (plain)" {
  run docker exec mail /bin/sh -c "nc -w 5 0.0.0.0 25 < /tmp/docker-mailserver-test/auth/added-smtp-auth-plain.txt | grep 'Authentication successful'"
  assert_success
}

@test "checking smtp: added user authentication fails with wrong password (plain)" {
  run docker exec mail /bin/sh -c "nc -w 20 0.0.0.0 25 < /tmp/docker-mailserver-test/auth/added-smtp-auth-plain-wrong.txt | grep 'authentication failed'"
  assert_success
}

@test "checking smtp: added user authentication works with good password (login)" {
  run docker exec mail /bin/sh -c "nc -w 5 0.0.0.0 25 < /tmp/docker-mailserver-test/auth/added-smtp-auth-login.txt | grep 'Authentication successful'"
  assert_success
}

@test "checking smtp: added user authentication fails with wrong password (login)" {
  run docker exec mail /bin/sh -c "nc -w 20 0.0.0.0 25 < /tmp/docker-mailserver-test/auth/added-smtp-auth-login-wrong.txt | grep 'authentication failed'"
  assert_success
}

@test "checking smtp: delivers mail to existing account" {
  run docker exec mail /bin/sh -c "grep 'postfix/lmtp' /var/log/mail/mail.log | grep 'status=sent' | grep ' Saved)' | sed 's/.* to=</</g' | sed 's/, relay.*//g' | sort | uniq -c | tr -s \" \""
  assert_success
  assert_output <<'EOF'
 1 <added@localhost.localdomain>
 6 <user1@localhost.localdomain>
 1 <user1@localhost.localdomain>, orig_to=<postmaster@my-domain.com>
 1 <user1@localhost.localdomain>, orig_to=<root>
 1 <user1~test@localhost.localdomain>
 2 <user2@otherdomain.tld>
EOF
}

@test "checking smtp: delivers mail to existing alias" {
  run docker exec mail /bin/sh -c "grep 'to=<user1@localhost.localdomain>, orig_to=<alias1@localhost.localdomain>' /var/log/mail/mail.log | grep 'status=sent' | wc -l"
  assert_success
  assert_output 1
}

@test "checking smtp: delivers mail to existing alias with recipient delimiter" {
  run docker exec mail /bin/sh -c "grep 'to=<user1~test@localhost.localdomain>, orig_to=<alias1~test@localhost.localdomain>' /var/log/mail/mail.log | grep 'status=sent' | wc -l"
  assert_success
  assert_output 1

  run docker exec mail /bin/sh -c "grep 'to=<user1~test@localhost.localdomain>' /var/log/mail/mail.log | grep 'status=bounced'"
  assert_failure
}

@test "checking smtp: delivers mail to existing catchall" {
  run docker exec mail /bin/sh -c "grep 'to=<user1@localhost.localdomain>, orig_to=<wildcard@localdomain2.com>' /var/log/mail/mail.log | grep 'status=sent' | wc -l"
  assert_success
  assert_output 1
}

@test "checking smtp: delivers mail to regexp alias" {
  run docker exec mail /bin/sh -c "grep 'to=<user1@localhost.localdomain>, orig_to=<test123@localhost.localdomain>' /var/log/mail/mail.log | grep 'status=sent' | wc -l"
  assert_success
  assert_output 1
}

@test "checking smtp: user1 should have received 9 mails" {
  run docker exec mail /bin/sh -c "grep Subject /var/mail/localhost.localdomain/user1/new/* | sed 's/.*Subject: //g' | sed 's/\.txt.*//g' | sed 's/VIRUS.*/VIRUS/g' | sort"
  assert_success
  # 9 messages, the virus mail has three subject lines
  cat <<'EOF' | assert_output
Root Test Message
Test Message amavis-virus
Test Message amavis-virus
Test Message existing-alias-external
Test Message existing-alias-recipient-delimiter
Test Message existing-catchall-local
Test Message existing-regexp-alias-local
Test Message existing-user-and-cc-local-alias
Test Message existing-user1
Test Message sieve-spam-folder
VIRUS
EOF
}

@test "checking smtp: rejects mail to unknown user" {
  run docker exec mail /bin/sh -c "grep '<nouser@localhost.localdomain>: Recipient address rejected: User unknown in virtual mailbox table' /var/log/mail/mail.log | wc -l"
  assert_success
  assert_output 1
}

@test "checking smtp: redirects mail to external aliases" {
  run docker exec mail /bin/sh -c "grep -- '-> <external1@otherdomain.tld>' /var/log/mail/mail.log* | grep RelayedInbound | wc -l"
  assert_success
  assert_output 2
}

@test "checking smtp: rejects spam" {
  run docker exec mail /bin/sh -c "grep 'Blocked SPAM' /var/log/mail/mail.log | grep external.tld=spam@my-domain.com | wc -l"
  assert_success
  assert_output 1
}

@test "checking smtp: rejects virus" {
  run docker exec mail /bin/sh -c "grep 'Blocked INFECTED' /var/log/mail/mail.log | grep external.tld=virus@my-domain.com | wc -l"
  assert_success
  assert_output 1
}

@test "checking smtp: not advertising smtputf8" {
  # Dovecot does not support SMTPUTF8, so while we can send we cannot receive
  # Better disable SMTPUTF8 support entirely if we can't handle it correctly
  run docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/smtp-ehlo.txt | grep SMTPUTF8 | wc -l"
  assert_success
  assert_output 0
}

#
# accounts
#

@test "checking accounts: user accounts" {
  run docker exec mail doveadm user '*'
  assert_success
  assert_line --index 0 "user1@localhost.localdomain"
  assert_line --index 1 "user2@otherdomain.tld"
  assert_line --index 2 "added@localhost.localdomain"
}

@test "checking accounts: user mail folder for user1" {
  run docker exec mail /bin/bash -c "ls -d /var/mail/localhost.localdomain/user1"
  assert_success
}

@test "checking accounts: user mail folder for user2" {
  run docker exec mail /bin/bash -c "ls -d /var/mail/otherdomain.tld/user2"
  assert_success
}

@test "checking accounts: user mail folder for added user" {
  run docker exec mail /bin/bash -c "ls -d /var/mail/localhost.localdomain/added"
  assert_success
}

@test "checking accounts: comments are not parsed" {
  run docker exec mail /bin/bash -c "ls /var/mail | grep 'comment'"
  assert_failure
}

#
# postfix
#

@test "checking postfix: vhost file is correct" {
  run docker exec mail cat /etc/postfix/vhost
  assert_success
  assert_line --index 0 "localdomain2.com"
  assert_line --index 1 "localhost.localdomain"
  assert_line --index 2 "otherdomain.tld"
}

@test "checking postfix: main.cf overrides" {
  run docker exec mail grep -q 'max_idle = 600s' /tmp/docker-mailserver/postfix-main.cf
  assert_success
  run docker exec mail grep -q 'readme_directory = /tmp' /tmp/docker-mailserver/postfix-main.cf
  assert_success
}

@test "checking postfix: master.cf overrides" {
  run docker exec mail grep -q 'submission/inet/smtpd_sasl_security_options=noanonymous' /tmp/docker-mailserver/postfix-master.cf
  assert_success
}

#
# dovecot
#

@test "checking dovecot: config additions" {
  run docker exec mail grep -q 'mail_max_userip_connections = 69' /tmp/docker-mailserver/dovecot.cf
  assert_success
  run docker exec mail /bin/sh -c "doveconf | grep 'mail_max_userip_connections = 69'"
  assert_success
  assert_output 'mail_max_userip_connections = 69'
}

#
# spamassassin
#

@test "checking spamassassin: should be listed in amavis when enabled" {
  run docker exec mail /bin/sh -c "grep -i 'ANTI-SPAM-SA code' /var/log/mail/mail.log | grep 'NOT loaded'"
  assert_failure
}

@test "checking spamassassin: all registered domains should see spam headers" {
  run docker exec mail /bin/sh -c "grep -ir 'X-Spam-' /var/mail/localhost.localdomain/user1/new"
  assert_success
  run docker exec mail /bin/sh -c "grep -ir 'X-Spam-' /var/mail/otherdomain.tld/user2/new"
  assert_success
}


#
# clamav
#

@test "checking clamav: should be listed in amavis when enabled" {
  run docker exec mail grep -i 'Found secondary av scanner ClamAV-clamscan' /var/log/mail/mail.log
  assert_success
}

#
# opendkim
#

@test "checking opendkim: /etc/opendkim/KeyTable should contain 2 entries" {
  run docker exec mail /bin/sh -c "cat /etc/opendkim/KeyTable | wc -l"
  assert_success
  assert_output 2
}

@test "checking opendkim: /etc/opendkim/KeyTable dummy file generated without keys provided" {
  docker run --rm -d --name mail_smtponly_without_config \
		-e SMTP_ONLY=1 \
		-e ENABLE_LDAP=1 \
		-e PERMIT_DOCKER=network \
		-e OVERRIDE_HOSTNAME=mail.mydomain.com \
		-t "${NAME}"

  teardown() { docker rm -f mail_smtponly_without_config; }

  run repeat_in_container_until_success_or_timeout 15 mail_smtponly_without_config /bin/bash -c "cat /etc/opendkim/KeyTable"
  assert_success
}


@test "checking opendkim: /etc/opendkim/keys/ should contain 2 entries" {
  run docker exec mail /bin/sh -c "ls -l /etc/opendkim/keys/ | grep '^d' | wc -l"
  assert_success
  assert_output 2
}

@test "checking opendkim: /etc/opendkim.conf contains nameservers copied from /etc/resolv.conf" {
  run docker exec mail /bin/bash -c "grep -E '^Nameservers ((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)' /etc/opendkim.conf"
  assert_success
}


# this set of tests is of low quality. It does not test the RSA-Key size properly via openssl or similar
# Instead it tests the file-size (here 861) - which may differ with a different domain names
# This test may be re-used as a global test to provide better test coverage.
@test "checking opendkim: generator creates default keys size" {
    local PRIVATE_CONFIG
    PRIVATE_CONFIG="$(duplicate_config_for_container . mail_default_key_size)"
    # Prepare default key size 4096
    rm -rf "${PRIVATE_CONFIG}/keyDefault"
    mkdir -p "${PRIVATE_CONFIG}/keyDefault"

    run docker run --rm \
      -v "${PRIVATE_CONFIG}/keyDefault/":/tmp/docker-mailserver/ \
      -v "${PRIVATE_CONFIG}/postfix-accounts.cf":/tmp/docker-mailserver/postfix-accounts.cf \
      -v "${PRIVATE_CONFIG}/postfix-virtual.cf":/tmp/docker-mailserver/postfix-virtual.cf \
      "${IMAGE_NAME:?}" /bin/sh -c 'generate-dkim-config | wc -l'
    assert_success
    assert_output 6

  run docker run --rm \
    -v "${PRIVATE_CONFIG}/keyDefault/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" \
    /bin/sh -c 'stat -c%s /etc/opendkim/keys/localhost.localdomain/mail.txt'

  assert_success
  assert_output 861
}

# this set of tests is of low quality. It does not test the RSA-Key size properly via openssl or similar
# this set of tests is of low quality. It does not test the RSA-Key size properly via openssl or similar
# Instead it tests the file-size (here 861) - which may differ with a different domain names
# This test may be re-used as a global test to provide better test coverage.
@test "checking opendkim: generator creates key size 4096" {
    local PRIVATE_CONFIG
    PRIVATE_CONFIG="$(duplicate_config_for_container . mail_key_size_4096)"
    # Prepare set key size 4096
    rm -rf "${PRIVATE_CONFIG}/key4096"
    mkdir -p "${PRIVATE_CONFIG}/config/key4096"
    run docker run --rm \
      -v "${PRIVATE_CONFIG}/key2048/":/tmp/docker-mailserver/ \
      -v "${PRIVATE_CONFIG}/postfix-accounts.cf":/tmp/docker-mailserver/postfix-accounts.cf \
      -v "${PRIVATE_CONFIG}/postfix-virtual.cf":/tmp/docker-mailserver/postfix-virtual.cf \
      "${IMAGE_NAME:?}" /bin/sh -c 'generate-dkim-config 4096 | wc -l'
    assert_success
    assert_output 6

  run docker run --rm \
    -v "${PRIVATE_CONFIG}/key2048/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" \
    /bin/sh -c 'stat -c%s /etc/opendkim/keys/localhost.localdomain/mail.txt'

  assert_success
  assert_output 861
}

# Instead it tests the file-size (here 511) - which may differ with a different domain names
# This test may be re-used as a global test to provide better test coverage.
@test "checking opendkim: generator creates key size 2048" {
    local PRIVATE_CONFIG
    PRIVATE_CONFIG="$(duplicate_config_for_container . mail_key_size_2048)"
    # Prepare set key size 2048
    rm -rf "${PRIVATE_CONFIG}/key2048"
    mkdir -p "${PRIVATE_CONFIG}/config/key2048"
    run docker run --rm \
      -v "${PRIVATE_CONFIG}/key2048/":/tmp/docker-mailserver/ \
      -v "${PRIVATE_CONFIG}/postfix-accounts.cf":/tmp/docker-mailserver/postfix-accounts.cf \
      -v "${PRIVATE_CONFIG}/postfix-virtual.cf":/tmp/docker-mailserver/postfix-virtual.cf \
      "${IMAGE_NAME:?}" /bin/sh -c 'generate-dkim-config 2048 | wc -l'
    assert_success
    assert_output 6

  run docker run --rm \
    -v "${PRIVATE_CONFIG}/key2048/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" \
    /bin/sh -c 'stat -c%s /etc/opendkim/keys/localhost.localdomain/mail.txt'

  assert_success
  assert_output 511
}

# this set of tests is of low quality. It does not test the RSA-Key size properly via openssl or similar
# Instead it tests the file-size (here 329) - which may differ with a different domain names
# This test may be re-used as a global test to provide better test coverage.
@test "checking opendkim: generator creates key size 1024" {
    local PRIVATE_CONFIG
    PRIVATE_CONFIG="$(duplicate_config_for_container . mail_key_size_1024)"
    # Prepare set key size 1024
    rm -rf "${PRIVATE_CONFIG}/key1024"
    mkdir -p "${PRIVATE_CONFIG}/key1024"
    run docker run --rm \
      -v "${PRIVATE_CONFIG}/key1024/":/tmp/docker-mailserver/ \
      -v "${PRIVATE_CONFIG}/postfix-accounts.cf":/tmp/docker-mailserver/postfix-accounts.cf \
      -v "${PRIVATE_CONFIG}/postfix-virtual.cf":/tmp/docker-mailserver/postfix-virtual.cf \
      "${IMAGE_NAME:?}" /bin/sh -c 'generate-dkim-config 1024 | wc -l'
    assert_success
    assert_output 6

  run docker run --rm \
    -v "${PRIVATE_CONFIG}/key1024/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" \
    /bin/sh -c 'stat -c%s /etc/opendkim/keys/localhost.localdomain/mail.txt'

  assert_success
  assert_output 329
}

@test "checking opendkim: generator creates keys, tables and TrustedHosts" {
  local PRIVATE_CONFIG
  PRIVATE_CONFIG="$(duplicate_config_for_container . mail_dkim_generator_creates_keys_tables_TrustedHosts)"
  rm -rf "${PRIVATE_CONFIG}/empty"
  mkdir -p "${PRIVATE_CONFIG}/empty"
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/empty/":/tmp/docker-mailserver/ \
    -v "${PRIVATE_CONFIG}/postfix-accounts.cf":/tmp/docker-mailserver/postfix-accounts.cf \
    -v "${PRIVATE_CONFIG}/postfix-virtual.cf":/tmp/docker-mailserver/postfix-virtual.cf \
    "${IMAGE_NAME:?}" /bin/sh -c 'generate-dkim-config | wc -l'
  assert_success
  assert_output 6
  # Check keys for localhost.localdomain
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/empty/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" /bin/sh -c 'ls -1 /etc/opendkim/keys/localhost.localdomain/ | wc -l'
  assert_success
  assert_output 2
  # Check keys for otherdomain.tld
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/empty/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" /bin/sh -c 'ls -1 /etc/opendkim/keys/otherdomain.tld | wc -l'
  assert_success
  assert_output 2
  # Check presence of tables and TrustedHosts
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/empty/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" /bin/sh -c "ls -1 /etc/opendkim | grep -E 'KeyTable|SigningTable|TrustedHosts|keys'|wc -l"
  assert_success
  assert_output 4
}

@test "checking opendkim: generator creates keys, tables and TrustedHosts without postfix-accounts.cf" {
  local PRIVATE_CONFIG
  PRIVATE_CONFIG="$(duplicate_config_for_container . )"
  rm -rf "${PRIVATE_CONFIG}/without-accounts"
  mkdir -p "${PRIVATE_CONFIG}/without-accounts"
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/without-accounts/":/tmp/docker-mailserver/ \
    -v "${PRIVATE_CONFIG}/postfix-virtual.cf":/tmp/docker-mailserver/postfix-virtual.cf \
    "${IMAGE_NAME:?}" /bin/sh -c 'generate-dkim-config | wc -l'
  assert_success
  assert_output 5
  # Check keys for localhost.localdomain
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/without-accounts/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" /bin/sh -c 'ls -1 /etc/opendkim/keys/localhost.localdomain/ | wc -l'
  assert_success
  assert_output 2
  # Check keys for otherdomain.tld
  # run docker run --rm \
  #   -v "${PRIVATE_CONFIG}/without-accounts/opendkim":/etc/opendkim \
  #   "${IMAGE_NAME:?}" /bin/sh -c 'ls -1 /etc/opendkim/keys/otherdomain.tld | wc -l'
  # assert_success
  # [ "${output}" -eq 0 ]
  # Check presence of tables and TrustedHosts
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/without-accounts/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" /bin/sh -c "ls -1 /etc/opendkim | grep -E 'KeyTable|SigningTable|TrustedHosts|keys'|wc -l"
  assert_success
  assert_output 4
}

@test "checking opendkim: generator creates keys, tables and TrustedHosts without postfix-virtual.cf" {
  local PRIVATE_CONFIG
  PRIVATE_CONFIG="$(duplicate_config_for_container . "${BATS_TEST_NAME}")"
  rm -rf "${PRIVATE_CONFIG}/without-virtual"
  mkdir -p "${PRIVATE_CONFIG}/without-virtual"
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/without-virtual/":/tmp/docker-mailserver/ \
    -v "${PRIVATE_CONFIG}/postfix-accounts.cf":/tmp/docker-mailserver/postfix-accounts.cf \
    "${IMAGE_NAME:?}" /bin/sh -c 'generate-dkim-config | wc -l'
  assert_success
  assert_output 5
  # Check keys for localhost.localdomain
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/without-virtual/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" /bin/sh -c 'ls -1 /etc/opendkim/keys/localhost.localdomain/ | wc -l'
  assert_success
  assert_output 2
  # Check keys for otherdomain.tld
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/without-virtual/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" /bin/sh -c 'ls -1 /etc/opendkim/keys/otherdomain.tld | wc -l'
  assert_success
  assert_output 2
  # Check presence of tables and TrustedHosts
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/without-virtual/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" /bin/sh -c "ls -1 /etc/opendkim | grep -E 'KeyTable|SigningTable|TrustedHosts|keys'|wc -l"
  assert_success
  assert_output 4
}

@test "checking opendkim: generator creates keys, tables and TrustedHosts using manual provided domain name" {
  local PRIVATE_CONFIG
  PRIVATE_CONFIG="$(duplicate_config_for_container . "${BATS_TEST_NAME}")"
  rm -rf "${PRIVATE_CONFIG}/with-domain" && mkdir -p "${PRIVATE_CONFIG}/with-domain"
  # Generate first key
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/with-domain/":/tmp/docker-mailserver/ \
    "${IMAGE_NAME:?}" /bin/sh -c 'generate-dkim-config 2048 domain1.tld| wc -l'
  assert_success
  assert_output 4
  # Generate two additional keys different to the previous one
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/with-domain/":/tmp/docker-mailserver/ \
    "${IMAGE_NAME:?}" /bin/sh -c 'generate-dkim-config 2048 'domain2.tld,domain3.tld' | wc -l'
  assert_success
  assert_output 2
  # Generate an additional key whilst providing already existing domains
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/with-domain/":/tmp/docker-mailserver/ \
    "${IMAGE_NAME:?}" /bin/sh -c 'generate-dkim-config 2048 'domain3.tld,domain4.tld' | wc -l'
  assert_success
  assert_output 1
  # Check keys for domain1.tld
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/with-domain/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" /bin/sh -c 'ls -1 /etc/opendkim/keys/domain1.tld/ | wc -l'
  assert_success
  assert_output 2
  # Check keys for domain2.tld
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/with-domain/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" /bin/sh -c 'ls -1 /etc/opendkim/keys/domain2.tld | wc -l'
  assert_success
  assert_output 2
  # Check keys for domain3.tld
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/with-domain/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" /bin/sh -c 'ls -1 /etc/opendkim/keys/domain3.tld | wc -l'
  assert_success
  assert_output 2
  # Check keys for domain4.tld
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/with-domain/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" /bin/sh -c 'ls -1 /etc/opendkim/keys/domain4.tld | wc -l'
  assert_success
  assert_output 2
  # Check presence of tables and TrustedHosts
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/with-domain/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" /bin/sh -c "ls -1 /etc/opendkim | grep -E 'KeyTable|SigningTable|TrustedHosts|keys' | wc -l"
  assert_success
  assert_output 4
  # Check valid entries actually present in KeyTable
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/with-domain/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" /bin/sh -c \
    "egrep 'domain1.tld|domain2.tld|domain3.tld|domain4.tld' /etc/opendkim/KeyTable | wc -l"
  assert_success
  assert_output 4
  # Check valid entries actually present in SigningTable
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/with-domain/opendkim":/etc/opendkim \
    "${IMAGE_NAME:?}" /bin/sh -c \
    "egrep 'domain1.tld|domain2.tld|domain3.tld|domain4.tld' /etc/opendkim/SigningTable | wc -l"
  assert_success
  assert_output 4
}

#
# ssl
#

@test "checking ssl: generated default cert works correctly" {
  run docker exec mail /bin/sh -c "timeout 1 openssl s_client -connect 0.0.0.0:587 -starttls smtp -CApath /etc/ssl/certs/ | grep 'Verify return code: 0 (ok)'"
  assert_success
}

@test "checking ssl: lets-encrypt-x3-cross-signed.pem is installed" {
  run docker exec mail grep 'BEGIN CERTIFICATE' /etc/ssl/certs/lets-encrypt-x3-cross-signed.pem
  assert_success
}

#
# postsrsd
#

@test "checking SRS: main.cf entries" {
  run docker exec mail grep "sender_canonical_maps = tcp:localhost:10001" /etc/postfix/main.cf
  assert_success
  run docker exec mail grep "sender_canonical_classes = envelope_sender" /etc/postfix/main.cf
  assert_success
  run docker exec mail grep "recipient_canonical_maps = tcp:localhost:10002" /etc/postfix/main.cf
  assert_success
  run docker exec mail grep "recipient_canonical_classes = envelope_recipient,header_recipient" /etc/postfix/main.cf
  assert_success
}

@test "checking SRS: postsrsd running" {
  run docker exec mail /bin/sh -c "ps aux | grep ^postsrsd"
  assert_success
}


@test "checking SRS: fallback to hostname is handled correctly" {
  run docker exec mail grep "SRS_DOMAIN=my-domain.com" /etc/default/postsrsd
  assert_success
}

#
# system
#

@test "checking system: freshclam cron is enabled" {
  run docker exec mail bash -c "grep '/usr/bin/freshclam' -r /etc/cron.d"
  assert_success
}

@test "checking amavis: virusmail wiper cron exists" {
  run docker exec mail bash -c "crontab -l | grep '/usr/local/bin/virus-wiper'"
  assert_success
}

@test "checking amavis: VIRUSMAILS_DELETE_DELAY override works as expected" {
  # shellcheck disable=SC2016
  run docker run --rm -e VIRUSMAILS_DELETE_DELAY=2 "${IMAGE_NAME:?}" /bin/bash -c 'echo "${VIRUSMAILS_DELETE_DELAY}"'
  assert_output 2
}

@test "checking amavis: old virusmail is wipped by cron" {
  docker exec mail bash -c 'touch -d "`date --date=2000-01-01`" /var/lib/amavis/virusmails/should-be-deleted'
  run docker exec mail bash -c '/usr/local/bin/virus-wiper'
  assert_success
  run docker exec mail bash -c 'ls -la /var/lib/amavis/virusmails/ | grep should-be-deleted'
  assert_failure
}

@test "checking amavis: recent virusmail is not wipped by cron" {
  docker exec mail bash -c 'touch -d "`date`"  /var/lib/amavis/virusmails/should-not-be-deleted'
  run docker exec mail bash -c '/usr/local/bin/virus-wiper'
  assert_success
  run docker exec mail bash -c 'ls -la /var/lib/amavis/virusmails/ | grep should-not-be-deleted'
  assert_success
}

@test "checking system: /var/log/mail/mail.log is error free" {
  run docker exec mail grep 'non-null host address bits in' /var/log/mail/mail.log
  assert_failure
  run docker exec mail grep 'mail system configuration error' /var/log/mail/mail.log
  assert_failure
  run docker exec mail grep ': error:' /var/log/mail/mail.log
  assert_failure
  run docker exec mail grep -i 'is not writable' /var/log/mail/mail.log
  assert_failure
  run docker exec mail grep -i 'permission denied' /var/log/mail/mail.log
  assert_failure
  run docker exec mail grep -i '(!)connect' /var/log/mail/mail.log
  assert_failure
  run docker exec mail grep -i 'backwards-compatible default setting chroot=y' /var/log/mail/mail.log
  assert_failure
  run docker exec mail grep -i 'connect to 127.0.0.1:10023: Connection refused' /var/log/mail/mail.log
  assert_failure
}

@test "checking system: /var/log/auth.log is error free" {
  run docker exec mail grep 'Unable to open env file: /etc/default/locale' /var/log/auth.log
  assert_failure
}

@test "checking system: sets the server fqdn" {
  run docker exec mail hostname
  assert_success
  assert_output "mail.my-domain.com"
}

@test "checking system: sets the server domain name in /etc/mailname" {
  run docker exec mail cat /etc/mailname
  assert_success
  assert_output "my-domain.com"
}

@test "checking system: postfix should not log to syslog" {
  run docker exec mail grep 'postfix' /var/log/syslog
  assert_failure
}

@test "checking system: amavis decoders installed and available" {
  run docker exec mail /bin/sh -c "grep -E '.*(Internal decoder|Found decoder) for\s+\..*' /var/log/mail/mail.log*|grep -Eo '(mail|Z|gz|bz2|xz|lzma|lrz|lzo|lz4|rpm|cpio|tar|deb|rar|arj|arc|zoo|doc|cab|tnef|zip|kmz|7z|jar|swf|lha|iso|exe)' | sort | uniq"
  assert_success
  # Support for doc and zoo removed in buster
  cat <<'EOF' | assert_output
7z
Z
arc
arj
bz2
cab
cpio
deb
exe
gz
iso
jar
kmz
lha
lrz
lz4
lzma
lzo
mail
rar
rpm
swf
tar
tnef
xz
zip
EOF
}


#
# sieve
#

@test "checking sieve: user1 should have received 1 email in folder INBOX.spam" {
  run docker exec mail /bin/sh -c "ls -A /var/mail/localhost.localdomain/user1/.INBOX.spam/new | wc -l"
  assert_success
  assert_output 1
}

@test "checking manage sieve: server is ready when ENABLE_MANAGESIEVE has been set" {
  run docker exec mail /bin/bash -c "nc -z 0.0.0.0 4190"
  assert_success
}

@test "checking sieve: user2 should have piped 1 email to /tmp/" {
  run docker exec mail /bin/sh -c "ls -A /tmp/pipe-test.out | wc -l"
  assert_success
  assert_output 1
}

@test "checking sieve global: user1 should have gotten a copy of his spam mail" {
  run docker exec mail /bin/sh -c "grep 'Spambot <spam@spam.com>' -R /var/mail/localhost.localdomain/user1/new/"
  assert_success
}

#
# accounts
#
@test "checking accounts: user_without_domain creation should be rejected since user@domain format is required" {
  run docker exec mail /bin/sh -c "addmailuser user_without_domain mypassword"
  assert_failure
  assert_output --partial "username must include the domain"
}

@test "checking accounts: user3 should have been added to /tmp/docker-mailserver/postfix-accounts.cf" {
  docker exec mail /bin/sh -c "addmailuser user3@domain.tld mypassword"

  run docker exec mail /bin/sh -c "grep '^user3@domain\.tld|' -i /tmp/docker-mailserver/postfix-accounts.cf"
  assert_success
  [ -n "${output}" ]
}

@test "checking accounts: auser3 should have been added to /tmp/docker-mailserver/postfix-accounts.cf" {
  docker exec mail /bin/sh -c "addmailuser auser3@domain.tld mypassword"

  run docker exec mail /bin/sh -c "grep '^auser3@domain\.tld|' -i /tmp/docker-mailserver/postfix-accounts.cf"
  assert_success
  [ -n "${output}" ]
}

@test "checking accounts: a.ser3 should have been added to /tmp/docker-mailserver/postfix-accounts.cf" {
  docker exec mail /bin/sh -c "addmailuser a.ser3@domain.tld mypassword"

  run docker exec mail /bin/sh -c "grep '^a\.ser3@domain\.tld|' -i /tmp/docker-mailserver/postfix-accounts.cf"
  assert_success
  [ -n "${output}" ]
}

@test "checking accounts: user3 should have been removed from /tmp/docker-mailserver/postfix-accounts.cf but not auser3" {
  docker exec mail /bin/sh -c "delmailuser -y user3@domain.tld"

  run docker exec mail /bin/sh -c "grep '^user3@domain\.tld' -i /tmp/docker-mailserver/postfix-accounts.cf"
  assert_failure
  [ -z "${output}" ]

  run docker exec mail /bin/sh -c "grep '^auser3@domain\.tld' -i /tmp/docker-mailserver/postfix-accounts.cf"
  assert_success
  [ -n "${output}" ]
}

@test "checking user updating password for user in /tmp/docker-mailserver/postfix-accounts.cf" {
  docker exec mail /bin/sh -c "addmailuser user4@domain.tld mypassword"

  initialpass=$(docker exec mail /bin/sh -c "grep '^user4@domain\.tld' -i /tmp/docker-mailserver/postfix-accounts.cf")
  sleep 2
  docker exec mail /bin/sh -c "updatemailuser user4@domain.tld mynewpassword"
  sleep 2
  changepass=$(docker exec mail /bin/sh -c "grep '^user4@domain\.tld' -i /tmp/docker-mailserver/postfix-accounts.cf")

  [ "${initialpass}" != "${changepass}" ]

  docker exec mail /bin/sh -c "delmailuser -y auser3@domain.tld"

  assert_success
}

@test "checking accounts: listmailuser" {
  run docker exec mail /bin/sh -c "listmailuser | head -n 1"
  assert_success
  assert_output 'user1@localhost.localdomain'
}

@test "checking accounts: no error is generated when deleting a user if /tmp/docker-mailserver/postfix-accounts.cf is missing" {
  run docker run --rm \
    -v "$(duplicate_config_for_container without-accounts/ without-accounts-deleting-user)":/tmp/docker-mailserver/ \
    "${IMAGE_NAME:?}" /bin/sh -c 'delmailuser -y user3@domain.tld'
  assert_success
  [ -z "${output}" ]
}

@test "checking accounts: user3 should have been added to /tmp/docker-mailserver/postfix-accounts.cf even when that file does not exist" {
  local PRIVATE_CONFIG
  PRIVATE_CONFIG=$(duplicate_config_for_container without-accounts/ without-accounts_file_does_not_exist)
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/without-accounts/":/tmp/docker-mailserver/ \
    "${IMAGE_NAME:?}" /bin/sh -c 'addmailuser user3@domain.tld mypassword'
  assert_success
  run docker run --rm \
    -v "${PRIVATE_CONFIG}/without-accounts/":/tmp/docker-mailserver/ \
    "${IMAGE_NAME:?}" /bin/sh -c 'grep user3@domain.tld -i /tmp/docker-mailserver/postfix-accounts.cf'
  assert_success
  [ -n "${output}" ]
}


@test "checking quota: setquota user must be existing" {
    run docker exec mail /bin/sh -c "addmailuser quota_user@domain.tld mypassword"
    assert_success

    run docker exec mail /bin/sh -c "setquota quota_user 50M"
    assert_failure
    run docker exec mail /bin/sh -c "setquota quota_user@domain.tld 50M"
    assert_success

    run docker exec mail /bin/sh -c "setquota username@fulldomain 50M"
    assert_failure

    run docker exec mail /bin/sh -c "delmailuser -y quota_user@domain.tld"
    assert_success
}
@test "checking quota: setquota <quota> must be well formatted" {
    run docker exec mail /bin/sh -c "addmailuser quota_user@domain.tld mypassword"
    assert_success

    run docker exec mail /bin/sh -c "setquota quota_user@domain.tld 26GIGOTS"
    assert_failure
    run docker exec mail /bin/sh -c "setquota quota_user@domain.tld 123"
    assert_failure
    run docker exec mail /bin/sh -c "setquota quota_user@domain.tld M"
    assert_failure
    run docker exec mail /bin/sh -c "setquota quota_user@domain.tld -60M"
    assert_failure


    run docker exec mail /bin/sh -c "setquota quota_user@domain.tld 10B"
    assert_success
    run docker exec mail /bin/sh -c "setquota quota_user@domain.tld 10k"
    assert_success
    run docker exec mail /bin/sh -c "setquota quota_user@domain.tld 10M"
    assert_success
    run docker exec mail /bin/sh -c "setquota quota_user@domain.tld 10G"
    assert_success
    run docker exec mail /bin/sh -c "setquota quota_user@domain.tld 10T"
    assert_success


    run docker exec mail /bin/sh -c "delmailuser -y quota_user@domain.tld"
    assert_success
}


@test "checking quota: delquota user must be existing" {
    run docker exec mail /bin/sh -c "addmailuser quota_user@domain.tld mypassword"
    assert_success

    run docker exec mail /bin/sh -c "delquota uota_user@domain.tld"
    assert_failure
    run docker exec mail /bin/sh -c "delquota quota_user"
    assert_failure
    run docker exec mail /bin/sh -c "delquota dontknowyou@domain.tld"
    assert_failure

    run docker exec mail /bin/sh -c "setquota quota_user@domain.tld 10T"
    assert_success
    run docker exec mail /bin/sh -c "delquota quota_user@domain.tld"
    assert_success
    run docker exec mail /bin/sh -c "grep -i 'quota_user@domain.tld' /tmp/docker-mailserver/dovecot-quotas.cf"
    assert_failure

    run docker exec mail /bin/sh -c "delmailuser -y quota_user@domain.tld"
    assert_success
}
@test "checking quota: delquota allow when no quota for existing user" {
    run docker exec mail /bin/sh -c "addmailuser quota_user@domain.tld mypassword"
    assert_success

    run docker exec mail /bin/sh -c "grep -i 'quota_user@domain.tld' /tmp/docker-mailserver/dovecot-quotas.cf"
    assert_failure

    run docker exec mail /bin/sh -c "delquota quota_user@domain.tld"
    assert_success
    run docker exec mail /bin/sh -c "delquota quota_user@domain.tld"
    assert_success

    run docker exec mail /bin/sh -c "delmailuser -y quota_user@domain.tld"
    assert_success
}

@test "checking quota: dovecot quota present in postconf" {
  run docker exec mail /bin/bash -c "postconf | grep 'check_policy_service inet:localhost:65265'"
  assert_success
}


@test "checking quota: dovecot mailbox max size must be equal to postfix mailbox max size" {
  postfix_mailbox_size=$(docker exec mail sh -c "postconf | grep -Po '(?<=mailbox_size_limit = )[0-9]+'")
  run echo "${postfix_mailbox_size}"
  refute_output ""

  # dovecot relies on virtual_mailbox_size by default
  postfix_virtual_mailbox_size=$(docker exec mail sh -c "postconf | grep -Po '(?<=virtual_mailbox_limit = )[0-9]+'")
  assert_equal "${postfix_virtual_mailbox_size}" "${postfix_mailbox_size}"

  postfix_mailbox_size_mb=$(( postfix_mailbox_size / 1000000))

  dovecot_mailbox_size_mb=$(docker exec mail sh -c "doveconf | grep  -oP '(?<=quota_rule \= \*\:storage=)[0-9]+'")
  run echo "${dovecot_mailbox_size_mb}"
  refute_output ""

  assert_equal "${postfix_mailbox_size_mb}" "${dovecot_mailbox_size_mb}"
}


@test "checking quota: dovecot message max size must be equal to postfix messsage max size" {
  postfix_message_size=$(docker exec mail sh -c "postconf | grep -Po '(?<=message_size_limit = )[0-9]+'")
  run echo "${postfix_message_size}"
  refute_output ""

  postfix_message_size_mb=$(( postfix_message_size / 1000000))

  dovecot_message_size_mb=$(docker exec mail sh -c "doveconf | grep  -oP '(?<=quota_max_mail_size = )[0-9]+'")
  run echo "${dovecot_message_size_mb}"
  refute_output ""

  assert_equal "${postfix_message_size_mb}" "${dovecot_message_size_mb}"
}

@test "checking quota: quota directive is removed when mailbox is removed" {
  run docker exec mail /bin/sh -c "addmailuser quserremoved@domain.tld mypassword"
  assert_success

  run docker exec mail /bin/sh -c "setquota quserremoved@domain.tld 12M"
  assert_success

  run docker exec mail /bin/sh -c 'cat /tmp/docker-mailserver/dovecot-quotas.cf | grep -E "^quserremoved@domain.tld\:12M\$" | wc -l | grep 1'
  assert_success

  run docker exec mail /bin/sh -c "delmailuser -y quserremoved@domain.tld"
  assert_success

  run docker exec mail /bin/sh -c 'cat /tmp/docker-mailserver/dovecot-quotas.cf | grep -E "^quserremoved@domain.tld\:12M\$"'
  assert_failure
}

@test "checking quota: dovecot applies user quota" {
  wait_for_changes_to_be_detected_in_container mail

  run docker exec mail /bin/sh -c "doveadm quota get -u 'user1@localhost.localdomain' | grep 'User quota STORAGE'"
  assert_output --partial "-                         0"

  run docker exec mail /bin/sh -c "setquota user1@localhost.localdomain 50M"
  assert_success

  wait_for_changes_to_be_detected_in_container mail

  # wait until quota has been updated
  run repeat_until_success_or_timeout 20 sh -c "docker exec mail sh -c 'doveadm quota get -u user1@localhost.localdomain | grep -oP \"(User quota STORAGE\s+[0-9]+\s+)51200(.*)\"'"
  assert_success

  run docker exec mail /bin/sh -c "delquota user1@localhost.localdomain"
  assert_success

  wait_for_changes_to_be_detected_in_container mail

  # wait until quota has been updated
  run repeat_until_success_or_timeout 20 sh -c "docker exec mail sh -c 'doveadm quota get -u user1@localhost.localdomain | grep -oP \"(User quota STORAGE\s+[0-9]+\s+)-(.*)\"'"
  assert_success
}

@test "checking quota: warn message received when quota exceeded" {
  wait_for_changes_to_be_detected_in_container mail

  # create user
  run docker exec mail /bin/sh -c "addmailuser quotauser@otherdomain.tld mypassword && setquota quotauser@otherdomain.tld 10k"
  assert_success

  wait_for_changes_to_be_detected_in_container mail

  # wait until quota has been updated
  run repeat_until_success_or_timeout 20 sh -c "docker exec mail sh -c 'doveadm quota get -u quotauser@otherdomain.tld | grep -oP \"(User quota STORAGE\s+[0-9]+\s+)10(.*)\"'"
  assert_success

  # dovecot and postfix has been restarted
  wait_for_service mail postfix
  wait_for_service mail dovecot
  sleep 10

  # send some big emails
  run docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/quota-exceeded.txt"
  assert_success
  run docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/quota-exceeded.txt"
  assert_success
  run docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/email-templates/quota-exceeded.txt"
  assert_success
  # check for quota warn message existence
  run repeat_until_success_or_timeout 20 sh -c "docker exec mail sh -c 'grep \"Subject: quota warning\" /var/mail/otherdomain.tld/quotauser/new/ -R'"
  assert_success

  run repeat_until_success_or_timeout 20 sh -c "docker logs mail | grep 'Quota exceeded (mailbox for user is full)'"
  assert_success

  # ensure only the first big message and the warn message are present (other messages are rejected: mailbox is full)
  run docker exec mail sh -c 'ls /var/mail/otherdomain.tld/quotauser/new/ | wc -l'
  assert_success
  assert_output "2"

  run docker exec mail /bin/sh -c "delmailuser -y quotauser@otherdomain.tld"
  assert_success
}

#
# PERMIT_DOCKER mynetworks
#

@test "checking PERMIT_DOCKER: can get container ip" {
  run docker exec mail /bin/sh -c "ip addr show eth0 | grep 'inet ' | sed 's/[^0-9\.\/]*//g' | cut -d '/' -f 1 | egrep '[[:digit:]]{1,3}\.[[:digit:]]{1,3}\.[[:digit:]]{1,3}\.[[:digit:]]{1,3}'"
  assert_success
}

@test "checking PERMIT_DOCKER: my network value" {
  run docker exec mail /bin/sh -c "postconf | grep '^mynetworks =' | egrep '[[:digit:]]{1,3}\.[[:digit:]]{1,3}\.0\.0/16'"
  assert_success
}

#
# amavis
#

@test "checking amavis: config overrides" {
  run docker exec mail /bin/sh -c "grep 'Test Verification' /etc/amavis/conf.d/50-user | wc -l"
  assert_success
  assert_output 1
}


@test "checking user login: predefined user can login" {
  run docker exec mail /bin/bash -c "doveadm auth test -x service=smtp pass@localhost.localdomain 'may be \\a \`p^a.*ssword' | grep 'passdb'"
  assert_output "passdb: pass@localhost.localdomain auth succeeded"
}

#
# setup.sh
#

# CLI interface
@test "checking setup.sh: Without arguments: status 1, show help text" {
  run ./setup.sh
  assert_failure
  assert_line --index 1 "Usage: ./setup.sh [-i IMAGE_NAME] [-c CONTAINER_NAME] <subcommand> <subcommand> [args]"
}

@test "checking setup.sh: Wrong arguments" {
  run ./setup.sh lol troll
  assert_failure
  assert_line --index 1 "Usage: ./setup.sh [-i IMAGE_NAME] [-c CONTAINER_NAME] <subcommand> <subcommand> [args]"
}

# email
@test "checking setup.sh: setup.sh email add and login" {
  wait_for_service mail changedetector
  assert_success

  run ./setup.sh -c mail email add setup_email_add@example.com test_password
  assert_success

  value=$(grep setup_email_add@example.com "$(private_config_path mail)/postfix-accounts.cf" | awk -F '|' '{print $1}')
  [ "${value}" = "setup_email_add@example.com" ]
  assert_success

  wait_for_changes_to_be_detected_in_container mail

  # Dovecot has been restarted, but this test often fails so presumably it may not be ready
  # Add a short sleep to see if that helps to make the test more stable
  # Alternatively we could login with a known good user to make sure that the service is up
  wait_for_service mail postfix
  wait_for_service mail dovecot
  sleep 5

  run docker exec mail /bin/bash -c "doveadm auth test -x service=smtp setup_email_add@example.com 'test_password' | grep 'passdb'"
  assert_output "passdb: setup_email_add@example.com auth succeeded"
}

@test "checking setup.sh: setup.sh email list" {
  run ./setup.sh -c mail email list
  assert_success
}

@test "checking setup.sh: setup.sh email update" {
  run ./setup.sh -c mail email add lorem@impsum.org test_test
  assert_success

  initialpass=$(grep lorem@impsum.org "$(private_config_path mail)/postfix-accounts.cf" | awk -F '|' '{print $2}')
  [ "${initialpass}" != "" ]
  assert_success

  run ./setup.sh -c mail email update lorem@impsum.org my password
  assert_success

  updatepass=$(grep lorem@impsum.org "$(private_config_path mail)/postfix-accounts.cf" | awk -F '|' '{print $2}')
  [ "${updatepass}" != "" ]
  [ "${initialpass}" != "${updatepass}" ]

  docker exec mail doveadm pw -t "${updatepass}" -p 'my password' | grep 'verified'
  assert_success
}

@test "checking setup.sh: setup.sh email del" {
  run ./setup.sh -c mail email del -y lorem@impsum.org
  assert_success
#
#  TODO delmailuser does not work as expected.
#  Its implementation is not functional, you cannot delete a user data
#  directory in the running container by running a new docker container
#  and not mounting the mail folders (persistance is broken).
#  The add script is only adding the user to account file.
#
#  run docker exec mail ls /var/mail/impsum.org/lorem
#  assert_failure
  run grep lorem@impsum.org "$(private_config_path mail)/postfix-accounts.cf"
  assert_failure
}

@test "checking setup.sh: setup.sh email restrict" {
  run ./setup.sh -c mail email restrict
  assert_failure
  run ./setup.sh -c mail email restrict add
  assert_failure
  ./setup.sh -c mail email restrict add send lorem@impsum.org
  run ./setup.sh -c mail email restrict list send
  assert_output --regexp "^lorem@impsum.org.*REJECT"

  run ./setup.sh -c mail email restrict del send lorem@impsum.org
  assert_success
  run ./setup.sh -c mail email restrict list send
  assert_output --partial "Everyone is allowed"

  ./setup.sh -c mail email restrict add receive rec_lorem@impsum.org
  run ./setup.sh -c mail email restrict list receive
  assert_output --regexp "^rec_lorem@impsum.org.*REJECT"
  run ./setup.sh -c mail email restrict del receive rec_lorem@impsum.org
  assert_success
}

# alias
@test "checking setup.sh: setup.sh alias list" {
  mkdir -p ./test/alias/config && echo "test@example.org test@forward.com" > ./test/alias/config/postfix-virtual.cf
  run ./setup.sh -p ./test/alias/config alias list
  assert_success
}
@test "checking setup.sh: setup.sh alias add" {
  mkdir -p ./test/alias/config && echo "" > ./test/alias/config/postfix-virtual.cf
  ./setup.sh -p ./test/alias/config alias add alias@example.com target1@forward.com
  ./setup.sh -p ./test/alias/config alias add alias@example.com target2@forward.com
  sleep 5
  run /bin/sh -c 'cat ./test/alias/config/postfix-virtual.cf | grep "alias@example.com target1@forward.com,target2@forward.com" | wc -l | grep 1'
  assert_success
}
@test "checking setup.sh: setup.sh alias del" {
  # start with a1 -> t1,t2 and a2 -> t1
  mkdir -p ./test/alias/config && echo -e 'alias1@example.org target1@forward.com,target2@forward.com\nalias2@example.org target1@forward.com' > ./test/alias/config/postfix-virtual.cf

  # we remove a1 -> t1 ==> a1 -> t2 and a2 -> t1
  ./setup.sh -p ./test/alias/config alias del alias1@example.org target1@forward.com
  run grep "target1@forward.com" ./test/alias/config/postfix-virtual.cf
  assert_output  --regexp "^alias2@example.org +target1@forward.com$"

  run grep "target2@forward.com" ./test/alias/config/postfix-virtual.cf
  assert_output  --regexp "^alias1@example.org +target2@forward.com$"

  # we remove a1 -> t2 ==> a2 -> t1
  ./setup.sh -p ./test/alias/config alias del alias1@example.org target2@forward.com
  run grep "alias1@example.org" ./test/alias/config/postfix-virtual.cf
  assert_failure

  run grep "alias2@example.org" ./test/alias/config/postfix-virtual.cf
  assert_success

  # we remove a2 -> t1 ==> empty
  ./setup.sh -p ./test/alias/config alias del alias2@example.org target1@forward.com
  run grep "alias2@example.org" ./test/alias/config/postfix-virtual.cf
  assert_failure
}

# quota
@test "checking setup.sh: setup.sh setquota" {
  mkdir -p ./test/quota/config && echo "" > ./test/quota/config/dovecot-quotas.cf

  run ./setup.sh -p ./test/quota/config email add quota_user@example.com test_password
  run ./setup.sh -p ./test/quota/config email add quota_user2@example.com test_password

  run ./setup.sh -p ./test/quota/config quota set quota_user@example.com 12M
  assert_success
  run ./setup.sh -p ./test/quota/config quota set 51M quota_user@example.com
  assert_failure
  run ./setup.sh -p ./test/quota/config quota set unknown@domain.com 150M
  assert_failure

  run ./setup.sh -p ./test/quota/config quota set quota_user2 51M
  assert_failure

  run /bin/sh -c 'cat ./test/quota/config/dovecot-quotas.cf | grep -E "^quota_user@example.com\:12M\$" | wc -l | grep 1'
  assert_success

  run ./setup.sh -p ./test/quota/config quota set quota_user@example.com 26M
  assert_success
  run /bin/sh -c 'cat ./test/quota/config/dovecot-quotas.cf | grep -E "^quota_user@example.com\:26M\$" | wc -l | grep 1'
  assert_success

  run grep "quota_user2@example.com" ./test/alias/config/dovecot-quotas.cf
  assert_failure
}

@test "checking setup.sh: setup.sh delquota" {
  mkdir -p ./test/quota/config && echo "" > ./test/quota/config/dovecot-quotas.cf

  run ./setup.sh -p ./test/quota/config email add quota_user@example.com test_password
  run ./setup.sh -p ./test/quota/config email add quota_user2@example.com test_password

  run ./setup.sh -p ./test/quota/config quota set quota_user@example.com 12M
  assert_success
  run /bin/sh -c 'cat ./test/quota/config/dovecot-quotas.cf | grep -E "^quota_user@example.com\:12M\$" | wc -l | grep 1'
  assert_success


  run ./setup.sh -p ./test/quota/config quota del unknown@domain.com
  assert_failure
  run /bin/sh -c 'cat ./test/quota/config/dovecot-quotas.cf | grep -E "^quota_user@example.com\:12M\$" | wc -l | grep 1'
  assert_success

  run ./setup.sh -p ./test/quota/config quota del quota_user@example.com
  assert_success
  run grep "quota_user@example.com" ./test/alias/config/dovecot-quotas.cf
  assert_failure
}



# config
@test "checking setup.sh: setup.sh config dkim" {
  run ./setup.sh -c mail config dkim
  assert_success
}
# TODO: To create a test generate-ssl-certificate must be non interactive
#@test "checking setup.sh: setup.sh config ssl" {
#  run ./setup.sh -c mail_ssl config ssl
#  assert_success
#}

# debug
@test "checking setup.sh: setup.sh debug fetchmail" {
  run ./setup.sh -c mail debug fetchmail
  assert_failure 11
  assert_output --partial "fetchmail: normal termination, status 11"
}
@test "checking setup.sh: setup.sh debug inspect" {
  run ./setup.sh -c mail debug inspect
  assert_success
  assert_line --index 0 "Image: ${NAME}"
  assert_line --index 1 "Container: mail"
}
@test "checking setup.sh: setup.sh debug login ls" {
  run ./setup.sh -c mail debug login ls
  assert_success
}

@test "checking setup.sh: setup.sh relay add-domain" {
  mkdir -p ./test/relay/config && echo -n > ./test/relay/config/postfix-relaymap.cf
  ./setup.sh -p ./test/relay/config relay add-domain example1.org smtp.relay1.com 2525
  ./setup.sh -p ./test/relay/config relay add-domain example2.org smtp.relay2.com
  ./setup.sh -p ./test/relay/config relay add-domain example3.org smtp.relay3.com 2525
  ./setup.sh -p ./test/relay/config relay add-domain example3.org smtp.relay.com 587

  # check adding
  run /bin/sh -c 'cat ./test/relay/config/postfix-relaymap.cf | grep -e "^@example1.org\s\+\[smtp.relay1.com\]:2525" | wc -l | grep 1'
  assert_success
  # test default port
  run /bin/sh -c 'cat ./test/relay/config/postfix-relaymap.cf | grep -e "^@example2.org\s\+\[smtp.relay2.com\]:25" | wc -l | grep 1'
  assert_success
  # test modifying
  run /bin/sh -c 'cat ./test/relay/config/postfix-relaymap.cf | grep -e "^@example3.org\s\+\[smtp.relay.com\]:587" | wc -l | grep 1'
  assert_success
}

@test "checking setup.sh: setup.sh relay add-auth" {
  mkdir -p ./test/relay/config && echo -n > ./test/relay/config/postfix-sasl-password.cf
  ./setup.sh -p ./test/relay/config relay add-auth example.org smtp_user smtp_pass
  ./setup.sh -p ./test/relay/config relay add-auth example2.org smtp_user2 smtp_pass2
  ./setup.sh -p ./test/relay/config relay add-auth example2.org smtp_user2 smtp_pass_new

  # test adding
  run /bin/sh -c 'cat ./test/relay/config/postfix-sasl-password.cf | grep -e "^@example.org\s\+smtp_user:smtp_pass" | wc -l | grep 1'
  assert_success
  # test updating
  run /bin/sh -c 'cat ./test/relay/config/postfix-sasl-password.cf | grep -e "^@example2.org\s\+smtp_user2:smtp_pass_new" | wc -l | grep 1'
  assert_success
}

@test "checking setup.sh: setup.sh relay exclude-domain" {
  mkdir -p ./test/relay/config && echo -n > ./test/relay/config/postfix-relaymap.cf
  ./setup.sh -p ./test/relay/config relay exclude-domain example.org

  run /bin/sh -c 'cat ./test/relay/config/postfix-relaymap.cf | grep -e "^@example.org\s*$" | wc -l | grep 1'
  assert_success
}

#
# LDAP
#

# postfix

@test "checking dovecot: postmaster address" {
  run docker exec mail /bin/sh -c "grep 'postmaster_address = postmaster@my-domain.com' /etc/dovecot/conf.d/15-lda.conf"
  assert_success
}

@test "checking spoofing: rejects sender forging" {
  # checking rejection of spoofed sender
  run docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/auth/added-smtp-auth-spoofed.txt"
  assert_output --partial 'Sender address rejected: not owned by user'
}

@test "checking spoofing: accepts sending as alias" {

  run docker exec mail /bin/sh -c "nc 0.0.0.0 25 < /tmp/docker-mailserver-test/auth/added-smtp-auth-spoofed-alias.txt | grep 'End data with'"
  assert_success
}

#
# Pflogsumm delivery check
#

@test "checking pflogsum delivery" {
  # checking logrotation working and report being sent
  docker exec mail logrotate --force /etc/logrotate.d/maillog
  sleep 10
  run docker exec mail grep "Subject: Postfix Summary for " /var/mail/localhost.localdomain/user1/new/ -R
  assert_success
  # check sender is the one specified in REPORT_SENDER
  run docker exec mail grep "From: report1@mail.my-domain.com" /var/mail/localhost.localdomain/user1/new/ -R
  assert_success
  # check sender is not the default one.
  run docker exec mail grep "From: mailserver-report@mail.my-domain.com" /var/mail/localhost.localdomain/user1/new/ -R
  assert_failure
}


#
# PCI compliance
#

# dovecot
@test "checking dovecot: only A grade TLS ciphers are used" {
  run docker run --rm -i --link mail:dovecot \
    --entrypoint sh instrumentisto/nmap -c \
      'nmap --script ssl-enum-ciphers -p 993 dovecot | grep "least strength: A"'
  assert_success
}

@test "checking dovecot: nmap produces no warnings on TLS ciphers verifying" {
  run docker run --rm -i --link mail:dovecot \
    --entrypoint sh instrumentisto/nmap -c \
      'nmap --script ssl-enum-ciphers -p 993 dovecot | grep "warnings" | wc -l'
  assert_success
  assert_output 0
}

# postfix submission TLS
@test "checking postfix submission: only A grade TLS ciphers are used" {
  run docker run --rm -i --link mail:postfix \
    --entrypoint sh instrumentisto/nmap -c \
      'nmap --script ssl-enum-ciphers -p 587 postfix | grep "least strength: A"'
  assert_success
}

@test "checking postfix submission: nmap produces no warnings on TLS ciphers verifying" {
  run docker run --rm -i --link mail:postfix \
    --entrypoint sh instrumentisto/nmap -c \
      'nmap --script ssl-enum-ciphers -p 587 postfix | grep "warnings" | wc -l'
  assert_success
  assert_output 0
}

# postfix smtps SSL
@test "checking postfix smtps: only A grade TLS ciphers are used" {
  run docker run --rm -i --link mail:postfix \
    --entrypoint sh instrumentisto/nmap -c \
      'nmap --script ssl-enum-ciphers -p 465 postfix | grep "least strength: A"'
  assert_success
}

@test "checking postfix smtps: nmap produces no warnings on TLS ciphers verifying" {
  run docker run --rm -i --link mail:postfix \
    --entrypoint sh instrumentisto/nmap -c \
      'nmap --script ssl-enum-ciphers -p 465 postfix | grep "warnings" | wc -l'
  assert_success
  assert_output 0
}


#
# supervisor
#

@test "checking restart of process: postfix" {
  run docker exec mail /bin/bash -c "pkill master && sleep 10 && ps aux --forest | grep -v grep | grep '/usr/lib/postfix/sbin/master'"
  assert_success
}

@test "checking restart of process: clamd" {
  run docker exec mail /bin/bash -c "pkill clamd && sleep 10 && ps aux --forest | grep -v grep | grep '/usr/sbin/clamd'"
  assert_success
}

@test "checking restart of process: amavisd-new" {
  run docker exec mail /bin/bash -c "pkill amavi && sleep 12 && ps aux --forest | grep -v grep | grep '/usr/sbin/amavisd-new (master)'"
  assert_success
}

@test "checking restart of process: opendkim" {
  run docker exec mail /bin/bash -c "pkill opendkim && sleep 10 && ps aux --forest | grep -v grep | grep '/usr/sbin/opendkim'"
  assert_success
}

@test "checking restart of process: opendmarc" {
  run docker exec mail /bin/bash -c "pkill opendmarc && sleep 10 && ps aux --forest | grep -v grep | grep '/usr/sbin/opendmarc'"
  assert_success
}

#
# root mail delivery
#

@test "checking that mail for root was delivered" {
  run docker exec mail grep "Subject: Root Test Message" /var/mail/localhost.localdomain/user1/new/ -R
  assert_success
}

@test "last" {
  skip 'this test is only there to reliably mark the end for the teardown_file (test.bats finished)'
}
