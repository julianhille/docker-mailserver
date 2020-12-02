# docker-mailserver-mysql

Fork of amazing [tomav/docker-mailserver](https://github.com/tomav/docker-mailserver) with MySQL support, so it can be managed by [postfixadmin](http://postfixadmin.sourceforge.net)

Please refer to [tomav/docker-mailserver](https://github.com/tomav/docker-mailserver) for documentation.

## Environment variables

Please refer to [tomav/docker-mailserver](https://github.com/tomav/docker-mailserver) for a full list of environment variables.

Here will be documented just the new MySQL environment variables.

### ENABLE_MYSQL
- **empty** => MYSQL authentification is disabled
- 1 => MYSQL authentification is enabled

### POSTFIX_MYSQL_HOSTS
- **empty** => 
- provide MySQL database host. TODO: specify if it accepts a list

### POSTFIX_MYSQL_DBNAME
- **empty** => 
- provide MySQL database name

### POSTFIX_MYSQL_USER
- **empty** => 
- provide MySQL database username

### POSTFIX_MYSQL_PASSWORD
- **empty** => 
- provide MySQL database password

### DOVECOT_MYSQL_DEFAULT_PASS_SCHEME
- **empty** => MD5-CRYPT
- provide value for `default_pass_scheme` variable in file `/etc/dovecot/dovecot-sql.conf.ext`

## Credits

* [tomav/docker-mailserver](https://github.com/tomav/docker-mailserver)

* [julianhille/docker-mailserver/tree/dovecot-mysql](https://github.com/julianhille/docker-mailserver/tree/dovecot-mysql) did the hard work to enable MySQL support to [tomav/docker-mailserver](https://github.com/tomav/docker-mailserver)
