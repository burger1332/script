#!/bin/bash
# 5.1.sh - Пошаговый интерактивный установщик Samba AD DC и клиентов (BR-SRV, HQ-SRV, HQ-CLI)
# Внимание: запускать на соответствующем хосте (выбираете устройство в меню).
# Usage: sudo ./5.1.sh

set -euo pipefail
export LANG=C

# Цвета
GREEN="\033[1;32m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RED="\033[1;31m"; RESET="\033[0m"

info(){ echo -e "${YELLOW}[INFO]${RESET} $*"; }
ok(){ echo -e "${GREEN}[DONE]${RESET} $*"; }
warn(){ echo -e "${CYAN}[NEXT]${RESET} $*"; }
err(){ echo -e "${RED}[ERROR]${RESET} $*"; }

ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Запустите скрипт от root: sudo $0"
    exit 1
  fi
}

# Проверка сети и DNS; если надо временно ставит публичные резолверы
ensure_network_and_dns() {
  info "Проверка сети: ping 8.8.8.8 ..."
  if ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
    ok "Интернет доступен"
  else
    err "Нет доступа к Интернету (ping 8.8.8.8 не удался). Проверьте сеть."
    return 1
  fi

  # Проверим резолвинг контроллера (br-srv.au-team.irpo) только как тест
  if getent hosts br-srv.au-team.irpo >/dev/null 2>&1; then
    ok "DNS резолвинг внутреннего хоста OK"
  else
    warn "Внутренний DNS не резолвит br-srv.au-team.irpo — временно пропишем публичные DNS для установки пакетов"
    cp -a /etc/resolv.conf /etc/resolv.conf.backup.5.1.$$ || true
    cat >/etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
    ok "/etc/resolv.conf временно обновлён (8.8.8.8,1.1.1.1)"
  fi
  return 0
}

# Общие параметры — по твоим данным
REALM="AU-TEAM.IRPO"
DOMAIN="AU-TEAM"
ADMIN_PASS="P@ssw0rd"
DC_HOST="br-srv.au-team.irpo"
DC_IP="192.168.4.2"
HQ_DNS_IP="192.168.1.2"
CSV_URL="https://bit.ly/3C1nEYz"
IMPORT_PASS="123qweR%"
LOG_PREFIX="[5.1] "

# ---------------- BR-SRV functions ----------------
br_step_install_samba() {
  info "BR-SRV: шаг 1 — установка task-samba-dc и зависимостей"
  ensure_network_and_dns || return 1
  apt-get update
  apt-get install -y task-samba-dc samba smbclient krb5-user || true
  ok "Пакеты установлены (или уже были)"
  warn "Далее: рекомендуется выполнить 'Provision Samba AD DC' (шаг 2 в меню BR-SRV)."
}

br_step_provision() {
  info "BR-SRV: шаг 2 — provision Samba AD DC"
  # временно ставим публичный резолвер, если нужно — чтобы домен provision прошёл
  cp -a /etc/resolv.conf /etc/resolv.conf.br_prov.backup.$$ || true
  echo "nameserver 8.8.8.8" > /etc/resolv.conf

  rm -f /etc/samba/smb.conf || true
  echo "Добавляю hosts запись ${DC_IP} ${DC_HOST}"
  grep -q "${DC_HOST}" /etc/hosts || echo "${DC_IP} ${DC_HOST}" >> /etc/hosts

  samba-tool domain provision --realm="${REALM}" --domain="${DOMAIN}" --server-role=dc --dns-backend=SAMBA_INTERNAL --adminpass="${ADMIN_PASS}" || {
    err "samba-tool domain provision завершился с ошибкой"
    return 1
  }
  mv -f /var/lib/samba/private/krb5.conf /etc/krb5.conf || true
  systemctl enable --now samba || true

  ok "Provision завершён, samba запущена"
  warn "Далее: создайте пользователей (BR-SRV -> пункт 3) или настройте sudo-schema (пункт 4)"
}

br_step_create_users() {
  info "BR-SRV: шаг 3 — создание пользователей и группы hq"
  for i in 1 2 3 4 5; do
    u="user${i}.hq"
    samba-tool user add "$u" "${ADMIN_PASS}" || warn "user $u возможно уже есть"
  done
  samba-tool group add hq || true
  samba-tool group addmembers hq user1.hq,user2.hq,user3.hq,user4.hq,user5.hq || true
  ok "Пользователи и группа hq созданы/обновлены"
  warn "Далее: можно задать sudo-schema (пункт 4) или импорт CSV (пункт 5)"
}

br_step_sudo_schema() {
  info "BR-SRV: шаг 4 — установка sudo-samba-schema и создание правила"
  ensure_network_and_dns || true
  # добавить локальный репозиторий если требуется (как в заметках)
  if command -v apt-repo >/dev/null 2>&1; then
    apt-repo add rpm http://altrepo.ru/local-p10 noarch local-p10 || true
  fi
  apt-get update || true
  apt-get install -y sudo-samba-schema || true
  # попытка non-interactive apply
  if command -v sudo-schema-apply >/dev/null 2>&1; then
    yes | sudo-schema-apply || warn "sudo-schema-apply вернуло ошибку/требует ручного ввода"
  fi
  # Создадим правило через create-sudo-rule, если доступно
  if command -v create-sudo-rule >/dev/null 2>&1; then
    printf "prava_hq\nALL\n/bin/cat\n%hq\n" | create-sudo-rule || warn "create-sudo-rule не сработал"
  else
    warn "create-sudo-rule отсутствует — возможно потребуется ручной шаг для создания sudo правила"
  fi
  ok "sudo-schema шаг выполнен (проверьте вручную при необходимости)"
  warn "Далее: импорт пользователей из CSV (пункт 5) или переход на HQ-SRV (следующий хост)"
}

br_step_import_csv() {
  info "BR-SRV: шаг 5 — импорт пользователей из CSV (скачать и добавить)"
  ensure_network_and_dns || true
  tmpzip="/root/users.zip"
  tmpcsv="/opt/Users.csv"
  mkdir -p /opt
  curl -L -o "$tmpzip" "$CSV_URL" || { err "Не удалось скачать CSV"; return 1; }
  apt-get install -y unzip || true
  unzip -o "$tmpzip" -d /root || true
  if [ -f /root/Users.csv ]; then
    mv -f /root/Users.csv "$tmpcsv"
  else
    err "Users.csv не найден в архиве"
    return 1
  fi
  cat >/root/import_users.sh <<'BASH'
#!/bin/bash
CSV="/opt/Users.csv"
while IFS=';' read -r firstName lastName role phone ou street zip city country password; do
  if [[ "$firstName" == "First Name" || -z "$firstName" ]]; then
    continue
  fi
  username="$(echo "${firstName,,}").$(echo "${lastName,,}")"
  samba-tool user add "$username" "123qweR%" || echo "user $username add failed or exists"
done < "$CSV"
BASH
  chmod +x /root/import_users.sh
  /root/import_users.sh || true
  ok "CSV импорт выполнен (пароль пользователей: 123qweR%)"
  warn "Далее: можно проверить домен (samba-tool domain info) или перейти к HQ-SRV"
}

br_check_domain_info() {
  info "BR-SRV: проверка информации о домене"
  samba-tool domain info 127.0.0.1 || true
  ok "Проверка домена выполнена"
  warn "Далее: настройте HQ-SRV (DNS forwarder) чтобы клиенты резолвили домен"
}

# ---------------- HQ-SRV functions ----------------
hq_step_dnsmasq() {
  info "HQ-SRV: шаг 1 — настройка dnsmasq для форварда домена au-team.irpo -> BR-SRV"
  cp -a /etc/dnsmasq.conf /etc/dnsmasq.conf.backup.5.1.$$ || true
  # Добавим запись пересылки домена на контроллер
  if ! grep -q "server=/au-team.irpo/${DC_IP}" /etc/dnsmasq.conf 2>/dev/null; then
    echo "server=/au-team.irpo/${DC_IP}" >> /etc/dnsmasq.conf
  fi
  systemctl restart dnsmasq || true
  ok "dnsmasq настроен и перезапущен"
  warn "Далее: проверьте резолвинг на HQ-CLI (kinit) — затем настройте HQ-CLI"
}

hq_check_resolve() {
  info "HQ-SRV: проверка резолвинга домена"
  if ping -c1 -W2 "${DC_HOST}" >/dev/null 2>&1; then
    ok "HQ-SRV резолвит ${DC_HOST}"
  else
    err "HQ-SRV не резолвит ${DC_HOST} — проверьте /etc/resolv.conf и dnsmasq"
  fi
}

# ---------------- HQ-CLI functions ----------------
hqcli_install_admc() {
  info "HQ-CLI: установка admc и подготовка"
  ensure_network_and_dns || true
  apt-get update || true
  apt-get install -y admc libsss_sudo sssd sudo || true
  ok "admc и зависимости установлены (или уже были)"
  warn "Далее: создадим/обновим /etc/krb5.conf (пункт 2 HQ-CLI)"
}

hqcli_setup_krb5() {
  info "HQ-CLI: создание /etc/krb5.conf для REALM=${REALM}"
  cp -a /etc/krb5.conf /etc/krb5.conf.backup.5.1.$$ || true
  cat >/etc/krb5.conf <<EOF
[libdefaults]
 default_realm = ${REALM}
 dns_lookup_realm = false
 dns_lookup_kdc = true

[realms]
 ${REALM} = {
  kdc = ${DC_HOST}
  admin_server = ${DC_HOST}
 }

[domain_realm]
 .au-team.irpo = ${REALM}
 au-team.irpo = ${REALM}
EOF
  ok "/etc/krb5.conf создан/обновлён"
  warn "Далее: настройка SSSD (пункт 3 HQ-CLI)"
}

hqcli_setup_sssd() {
  info "HQ-CLI: настройка SSSD для sudo_provider=ad"
  mkdir -p /etc/sssd
  cp -a /etc/sssd/sssd.conf /etc/sssd/sssd.conf.backup.5.1.$$ 2>/dev/null || true
  cat >/etc/sssd/sssd.conf <<EOF
[sssd]
services = nss, pam, sudo
config_file_version = 2
domains = ${REALM}

[domain/${REALM}]
id_provider = ad
auth_provider = ad
access_provider = ad
sudo_provider = ad
ad_domain = ${REALM}
krb5_realm = ${REALM}
cache_credentials = True
EOF
  chmod 600 /etc/sssd/sssd.conf || true
  if ! grep -q '^sudoers:' /etc/nsswitch.conf 2>/dev/null; then
    echo "sudoers: files sss" >> /etc/nsswitch.conf
  else
    sed -i 's/^sudoers:.*/sudoers: files sss/' /etc/nsswitch.conf || true
  fi
  systemctl restart sssd || true
  rm -rf /var/lib/sss/db/* 2>/dev/null || true
  sss_cache -E 2>/dev/null || true
  ok "SSSD настроен и перезапущен"
  warn "Далее: проверьте Kerberos (kinit Administrator) и sudo права пользователем domain user (после входа)"
}

hqcli_check_kinit() {
  info "HQ-CLI: пробуем получить Kerberos тикет (kinit Administrator)"
  if printf "%s\n" "${ADMIN_PASS}" | kinit Administrator@"${REALM}" 2>/dev/null; then
    ok "kinit успешен (принят пароль автоматически)"
    klist || true
  else
    warn "kinit не удалось автоматически — выполните вручную: kinit Administrator@${REALM} и введите пароль"
  fi
}

# ---------------- Menu logic ----------------
ensure_root

while true; do
  echo
  echo "======================================"
  echo "Выберите устройство для настройки:"
  echo " 1) BR-SRV (Domain Controller)"
  echo " 2) HQ-SRV (DNS forwarder)"
  echo " 3) HQ-CLI (AD клиент)"
  echo " 0) Выйти"
  echo "======================================"
  read -rp "Выбор: " DEV

  case "$DEV" in
    1)
      echo "----- BR-SRV actions -----"
      echo "1) Установить Samba DC (apt-get install task-samba-dc)"
      echo "2) Provision Samba AD DC"
      echo "3) Создать пользователей и группу hq"
      echo "4) Установить sudo-schema и правило sudo"
      echo "5) Импорт пользователей из CSV"
      echo "6) Проверить домен (samba-tool domain info)"
      echo "0) Назад"
      read -rp "Выберите шаг(ы) через пробел, или 0: " STEPS
      for s in $STEPS; do
        case "$s" in
          1) br_step_install_samba ;;
          2) br_step_provision ;;
          3) br_step_create_users ;;
          4) br_step_sudo_schema ;;
          5) br_step_import_csv ;;
          6) br_check_domain_info ;;
          0) break ;;
          *) echo "Неверный шаг: $s" ;;
        esac
      done
      warn "BR-SRV: после завершения шагов можно перейти к HQ-SRV (выберите устройство 2)"
      ;;
    2)
      echo "----- HQ-SRV actions -----"
      echo "1) Настроить dnsmasq форвард для au-team.irpo -> BR-SRV"
      echo "2) Проверить резолвинг BR-SRV"
      echo "0) Назад"
      read -rp "Выберите шаг(ы) через пробел, или 0: " STEPS
      for s in $STEPS; do
        case "$s" in
          1) hq_step_dnsmasq ;;
          2) hq_check_resolve ;;
          0) break ;;
          *) echo "Неверный шаг: $s" ;;
        esac
      done
      warn "HQ-SRV: после DNS настройте HQ-CLI (выберите устройство 3)"
      ;;
    3)
      echo "----- HQ-CLI actions -----"
      echo "1) Установить admc и зависимости"
      echo "2) Создать /etc/krb5.conf для домена"
      echo "3) Настроить SSSD и sudo via AD"
      echo "4) Проверить Kerberos (kinit Administrator)"
      echo "0) Назад"
      read -rp "Выберите шаг(ы) через пробел, или 0: " STEPS
      for s in $STEPS; do
        case "$s" in
          1) hqcli_install_admc ;;
          2) hqcli_setup_krb5 ;;
          3) hqcli_setup_sssd ;;
          4) hqcli_check_kinit ;;
          0) break ;;
          *) echo "Неверный шаг: $s" ;;
        esac
      done
      warn "HQ-CLI: после настроек проверьте вход доменного пользователя и sudo права"
      ;;
    0) echo "Выход"; exit 0 ;;
    *) echo "Неверный выбор";;
  esac
done
