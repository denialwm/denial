# packages.denialwm.org

The host of Denial's Pacman, APT and DNF repositories. The release workflow
fills it with `tools/publish-denial-packages`; nothing else writes to it.

| Path | Holds |
|---|---|
| `arch/$arch/` | Pacman repository `denial`, x86_64 and aarch64 |
| `apt/` | APT repository, suites `trixie` and `noble` |
| `rpm/fedora/$releasever/$basearch/` | DNF repository |
| `denial-repo-key.asc` | the signing key |
| `install.sh`, `denial-*.sources`, `denial-fedora.repo` | repository setup |
| `.manifest` | the files of the release the server holds |

Every package and index is signed. The server only stores and serves them:
clients trust the key, not the host.

## Server

An Oracle Linux 9 virtual machine. The setup, as root:

```sh
dnf install -y nginx rsync oracle-epel-release-el9
dnf config-manager --set-enabled ol9_developer_EPEL
dnf install -y certbot

# The upload account: rsync into /srv/packages and nothing else.
useradd --system --create-home --shell /bin/sh packages
install -d -o packages -g packages -m 0755 /srv/packages
install -m 0755 /usr/share/doc/rsync/support/rrsync /usr/local/bin/rrsync
install -d -o packages -g packages -m 0700 /home/packages/.ssh
printf 'command="/usr/local/bin/rrsync /srv/packages",restrict %s\n' \
  "$(cat packages-upload.pub)" >/home/packages/.ssh/authorized_keys
chown packages:packages /home/packages/.ssh/authorized_keys
chmod 0600 /home/packages/.ssh/authorized_keys

semanage fcontext -a -t httpd_sys_content_t '/srv/packages(/.*)?'
restorecon -R /srv/packages
install -d -m 0755 /var/www/acme

firewall-cmd --permanent --add-service=http --add-service=https
firewall-cmd --reload
```

The certificate needs the HTTP block alone first: install `nginx.conf` with
the 443 block left out, start nginx, then

```sh
certbot certonly --webroot -w /var/www/acme -d packages.denialwm.org
```

and install the whole `nginx.conf` as
`/etc/nginx/conf.d/packages.denialwm.org.conf`. Renewal runs from
`certbot-renew.timer`; a deploy hook reloads nginx:

```sh
printf '#!/bin/sh\nsystemctl reload nginx\n' \
  >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx
systemctl enable --now certbot-renew.timer
```

The DNS record is an A record, not proxied through Cloudflare.

## Upload key

The private half is the `DENIAL_PACKAGES_UPLOAD_KEY` secret of the
`github-pages` environment, the environment of the release workflow's publish
job. The public half is in `/home/packages/.ssh/authorized_keys`. A new key
replaces both.

`known_hosts` pins the server's host key. A new server needs a new line.
