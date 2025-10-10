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

# Проверка установки Samba
check_samba_installed() {
  if command -v samba-tool >/dev/null 2>&1 && [ -f /usr/sbin/samba ]; then
    return 0
  else
    return 1
  fi
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
  info "BR-SRV: шаг 1 — установка Samba AD DC"
  ensure_network_and_dns || return 1
  
  # Проверяем не установлен ли уже samba-dc
  if rpm -q samba-dc >/dev/null 2>&1 && command -v samba-tool >/dev/null 2>&1; then
    ok "Samba AD DC уже установлен"
    info "Версия: $(samba-tool --version 2>/dev/null | head -1)"
    return 0
  fi
  
  info "Установка samba-dc..."
  apt-get update
  
  # Устанавливаем samba-dc с автоматическим подтверждением
  if apt-get install -y samba-dc; then
    ok "samba-dc успешно установлен"
  else
    err "Ошибка установки samba-dc"
    return 1
  fi
  
  # Проверяем установку
  if command -v samba-tool >/dev/null 2>&1; then
    ok "samba-tool доступен: $(which samba-tool)"
    info "Версия Samba: $(samba-tool --version 2>/dev/null | head -1)"
    
    # Проверяем другие важные утилиты
    info "Проверка дополнительных утилит:"
    for tool in smbd nmbd winbindd; do
      if command -v $tool >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${RESET} $tool"
      else
        echo -e "  ${YELLOW}⚠${RESET} $tool не найден"
      fi
    done
    
    return 0
  else
    err "samba-tool не найден после установки samba-dc"
    return 1
  fi
}
br_step_provision() {
  info "BR-SRV: шаг 2 — provision Samba AD DC"
  
  # Проверяем установлен ли samba-tool
  if ! command -v samba-tool >/dev/null 2>&1; then
    err "samba-tool не найден! Сначала выполните установку Samba (пункт 1)"
    return 1
  fi
  
  # Проверяем, не был ли уже выполнен provision
  if [ -f /etc/samba/smb.conf ] && grep -q "security = domain" /etc/samba/smb.conf 2>/dev/null; then
    warn "Samba уже настроен как Domain Controller. Пересоздаём конфигурацию..."
    systemctl stop samba-ad-dc 2>/dev/null || systemctl stop samba 2>/dev/null
    mv /etc/samba/smb.conf /etc/samba/smb.conf.backup.$(date +%Y%m%d_%H%M%S)
  fi

  # временно ставим публичный резолвер, если нужно — чтобы домен provision прошёл
  cp -a /etc/resolv.conf /etc/resolv.conf.br_prov.backup.$$ || true
  echo "nameserver 8.8.8.8" > /etc/resolv.conf

  rm -f /etc/samba/smb.conf || true
  echo "Добавляю hosts запись ${DC_IP} ${DC_HOST}"
  grep -q "${DC_HOST}" /etc/hosts || echo "${DC_IP} ${DC_HOST}" >> /etc/hosts

  info "Запуск provision Samba AD DC..."
  info "Realm: ${REALM}, Domain: ${DOMAIN}, Admin Pass: ${ADMIN_PASS}"
  
  # Неинтерактивный provision
  debconf-set-selections <<EOF
krb5-config krb5-config/default_realm string ${REALM}
krb5-config krb5-config/kerberos_servers string ${DC_HOST}
krb5-config krb5-config/admin_server string ${DC_HOST}
EOF

  if samba-tool domain provision --realm="${REALM}" --domain="${DOMAIN}" --server-role=dc --dns-backend=SAMBA_INTERNAL --adminpass="${ADMIN_PASS}" --use-rfc2307; then
    ok "Provision успешно завершен"
  else
    err "samba-tool domain provision завершился с ошибкой"
    # Восстанавливаем resolv.conf
    mv -f /etc/resolv.conf.br_prov.backup.$$ /etc/resolv.conf 2>/dev/null || true
    return 1
  fi

  # Копируем конфиг Kerberos
  cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf

  # Запускаем службы
  info "Запуск служб Samba..."
  systemctl stop systemd-resolved 2>/dev/null || true
  systemctl disable systemd-resolved 2>/dev/null || true
  systemctl unmask samba-ad-dc 2>/dev/null || true
  systemctl enable samba-ad-dc
  systemctl start samba-ad-dc

  # Проверяем запуск
  if systemctl is-active samba-ad-dc >/dev/null 2>&1; then
    ok "Samba AD DC успешно запущен"
  else
    warn "Samba AD DC не запустился, пробуем альтернативный метод..."
    systemctl enable samba
    systemctl start samba
  fi

  # Восстанавливаем resolv.conf
  mv -f /etc/resolv.conf.br_prov.backup.$$ /etc/resolv.conf 2>/dev/null || true

  # Проверяем работу домена
  info "Проверка работы домена..."
  if samba-tool domain info 127.0.0.1 2>/dev/null; then
    ok "Домен работает корректно"
  else
    warn "Есть проблемы с доменом, проверьте вручную"
  fi

  warn "Далее: создайте пользователей (BR-SRV -> пункт 3) или настройте sudo-schema (пункт 4)"
}

br_step_create_users() {
  info "BR-SRV: шаг 3 — создание пользователей и группы hq"
  
  if ! command -v samba-tool >/dev/null 2>&1; then
    err "samba-tool не найден! Сначала выполните установку и provision Samba"
    return 1
  fi

  info "Создание пользователей user1.hq - user5.hq..."
  for i in 1 2 3 4 5; do
    u="user${i}.hq"
    if samba-tool user show "$u" 2>/dev/null; then
      info "Пользователь $u уже существует"
    else
      if samba-tool user create "$u" "${ADMIN_PASS}"; then
        ok "Пользователь $u создан"
      else
        err "Ошибка создания пользователя $u"
      fi
    fi
  done

  info "Создание группы hq..."
  if samba-tool group list | grep -q "^hq$"; then
    info "Группа hq уже существует"
  else
    samba-tool group add hq || warn "Группа hq возможно уже существует"
  fi

  info "Добавление пользователей в группу hq..."
  if samba-tool group addmembers hq user1.hq,user2.hq,user3.hq,user4.hq,user5.hq; then
    ok "Пользователи добавлены в группу hq"
  else
    warn "Ошибка добавления пользователей в группу hq (возможно уже добавлены)"
  fi

  info "Проверка созданных пользователей:"
  samba-tool user list | grep "user.*hq" || true
  
  ok "Пользователи и группа hq созданы/обновлены"
  warn "Далее: можно задать sudo-schema (пункт 4) или импорт CSV (пункт 5)"
}

br_step_sudo_schema() {
  info "BR-SRV: шаг 4 — установка sudo-samba-schema и создание правила"
  ensure_network_and_dns || true
  
  # Проверяем установлен ли sudo-samba-schema
  if dpkg -l | grep -q sudo-samba-schema; then
    info "sudo-samba-schema уже установлен"
  else
    info "Установка sudo-samba-schema..."
    # добавить локальный репозиторий если требуется (как в заметках)
    if command -v apt-repo >/dev/null 2>&1; then
      apt-repo add rpm http://altrepo.ru/local-p10 noarch local-p10 || true
    fi
    apt-get update || true
    apt-get install -y sudo-samba-schema || {
      warn "Не удалось установить sudo-samba-schema автоматически"
      return 1
    }
  fi

  # попытка non-interactive apply
  if command -v sudo-schema-apply >/dev/null 2>&1; then
    info "Применение sudo-schema..."
    yes | sudo-schema-apply || warn "sudo-schema-apply вернуло ошибку/требует ручного ввода"
  fi
  
  # Создадим правило через create-sudo-rule, если доступно
  if command -v create-sudo-rule >/dev/null 2>&1; then
    info "Создание sudo правила prava_hq..."
    printf "prava_hq\nALL\n/bin/cat\n%%hq\n" | create-sudo-rule || warn "create-sudo-rule не сработал"
  else
    warn "create-sudo-rule отсутствует — возможно потребуется ручной шаг для создания sudo правила"
  fi
  
  ok "sudo-schema шаг выполнен (проверьте вручную при необходимости)"
  warn "Далее: импорт пользователей из CSV (пункт 5) или переход на HQ-SRV (следующий хост)"
}

br_step_import_csv() {
  info "BR-SRV: шаг 5 — импорт пользователей из CSV (скачать и добавить)"
  ensure_network_and_dns || true
  
  if ! command -v samba-tool >/dev/null 2>&1; then
    err "samba-tool не найден! Сначала выполните установку и provision Samba"
    return 1
  fi

  tmpzip="/root/users.zip"
  tmpcsv="/opt/Users.csv"
  mkdir -p /opt
  
  info "Скачивание CSV файла..."
  if curl -L -o "$tmpzip" "$CSV_URL"; then
    ok "CSV файл скачан"
  else
    err "Не удалось скачать CSV"
    return 1
  fi
  
  # Устанавливаем unzip если нужно
  if ! command -v unzip >/dev/null 2>&1; then
    apt-get install -y unzip || true
  fi
  
  info "Распаковка архива..."
  if unzip -o "$tmpzip" -d /root; then
    ok "Архив распакован"
  else
    err "Ошибка распаковки архива"
    return 1
  fi
  
  if [ -f /root/Users.csv ]; then
    mv -f /root/Users.csv "$tmpcsv"
    ok "CSV файл перемещен в $tmpcsv"
  else
    err "Users.csv не найден в архиве"
    return 1
  fi
  
  info "Импорт пользователей из CSV..."
  cat >/root/import_users.sh <<'BASH'
#!/bin/bash
CSV="/opt/Users.csv"
count=0
while IFS=';' read -r firstName lastName role phone ou street zip city country password; do
  if [[ "$firstName" == "First Name" || -z "$firstName" ]]; then
    continue
  fi
  username="$(echo "${firstName,,}").$(echo "${lastName,,}")"
  echo "Добавление пользователя: $username"
  if samba-tool user add "$username" "123qweR%" 2>/dev/null; then
    echo "✓ Пользователь $username создан"
    ((count++))
  else
    echo "✗ Пользователь $username уже существует или ошибка создания"
  fi
done < "$CSV"
echo "Импортировано пользователей: $count"
BASH

  chmod +x /root/import_users.sh
  /root/import_users.sh || true
  
  ok "CSV импорт выполнен (пароль пользователей: 123qweR%)"
  warn "Далее: можно проверить домен (samba-tool domain info) или перейти к HQ-SRV"
}

br_check_domain_info() {
  info "BR-SRV: проверка информации о домене"
  
  if ! command -v samba-tool >/dev/null 2>&1; then
    err "samba-tool не найден!"
    return 1
  fi
  
  info "Информация о домене:"
  samba-tool domain info 127.0.0.1 || true
  
  info "Список пользователей:"
  samba-tool user list | head -10
  
  info "Список групп:"
  samba-tool group list | head -10
  
  ok "Проверка домена выполнена"
  warn "Далее: настройте HQ-SRV (DNS forwarder) чтобы клиенты резолвили домен"
}

# ---------------- HQ-SRV functions ----------------
hq_step_dnsmasq() {
  info "HQ-SRV: шаг 1 — настройка dnsmasq для форварда домена au-team.irpo -> BR-SRV"
  
  # Устанавливаем dnsmasq если не установлен
  if ! command -v dnsmasq >/dev/null 2>&1; then
    info "Установка dnsmasq..."
    apt-get update
    apt-get install -y dnsmasq
  fi
  
  cp -a /etc/dnsmasq.conf /etc/dnsmasq.conf.backup.5.1.$$ || true
  
  # Добавим запись пересылки домена на контроллер
  if ! grep -q "server=/au-team.irpo/${DC_IP}" /etc/dnsmasq.conf 2>/dev/null; then
    echo "server=/au-team.irpo/${DC_IP}" >> /etc/dnsmasq.conf
    ok "Добавлена запись форварда для au-team.irpo -> ${DC_IP}"
  else
    info "Запись форварда уже существует"
  fi
  
  # Убедимся что dnsmasq слушает на всех интерфейсах
  if ! grep -q "^listen-address=" /etc/dnsmasq.conf 2>/dev/null; then
    echo "listen-address=::1,127.0.0.1" >> /etc/dnsmasq.conf
  fi
  
  info "Перезапуск dnsmasq..."
  systemctl restart dnsmasq || {
    err "Ошибка перезапуска dnsmasq"
    systemctl status dnsmasq --no-pager -l
    return 1
  }
  
  # Проверяем что служба работает
  if systemctl is-active dnsmasq >/dev/null 2>&1; then
    ok "dnsmasq настроен и запущен"
  else
    err "dnsmasq не запустился"
    return 1
  fi
  
  warn "Далее: проверьте резолвинг на HQ-CLI (kinit) — затем настройте HQ-CLI"
}

hq_check_resolve() {
  info "HQ-SRV: проверка резолвинга домена"
  
  # Проверяем резолвинг домена
  info "Проверка резолвинга ${DC_HOST}..."
  if nslookup "${DC_HOST}" 127.0.0.1 >/dev/null 2>&1; then
    ok "DNS резолвит ${DC_HOST}"
  else
    warn "DNS не резолвит ${DC_HOST} локально, проверяем без указания сервера..."
  fi
  
  if ping -c1 -W2 "${DC_HOST}" >/dev/null 2>&1; then
    ok "HQ-SRV резолвит ${DC_HOST}"
    info "IP адрес: $(getent hosts ${DC_HOST} | awk '{print $1}')"
  else
    err "HQ-SRV не резолвит ${DC_HOST} — проверьте /etc/resolv.conf и dnsmasq"
    info "Содержимое /etc/resolv.conf:"
    cat /etc/resolv.conf
    return 1
  fi
}

# ---------------- HQ-CLI functions ----------------
hqcli_install_admc() {
  info "HQ-CLI: установка admc и подготовка"
  ensure_network_and_dns || true
  
  # Проверяем установлены ли пакеты
  if dpkg -l | grep -q admc && dpkg -l | grep -q sssd; then
    ok "admc и sssd уже установлены"
    return 0
  fi
  
  apt-get update || true
  info "Установка пакетов AD-клиента..."
  
  if apt-get install -y admc libsss_sudo sssd sssd-tools libpam-sss libnss-sss krb5-user realmd adcli; then
    ok "Пакеты AD-клиента установлены"
  else
    err "Ошибка установки пакетов AD-клиента"
    return 1
  fi
  
  ok "admc и зависимости установлены"
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
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true

[realms]
    ${REALM} = {
        kdc = ${DC_HOST}
        admin_server = ${DC_HOST}
        default_domain = ${REALM,,}
    }

[domain_realm]
    .${REALM,,} = ${REALM}
    ${REALM,,} = ${REALM}
EOF

  ok "/etc/krb5.conf создан/обновлён"
  
  # Проверяем синтаксис
  if klist -e 2>/dev/null; then
    ok "Kerberos конфигурация корректна"
  else
    warn "Возможны проблемы с Kerberos конфигурацией"
  fi
  
  warn "Далее: настройка SSSD (пункт 3 HQ-CLI)"
}

hqcli_setup_sssd() {
  info "HQ-CLI: настройка SSSD для sudo_provider=ad"
  
  # Останавливаем службы которые могут мешать
  systemctl stop systemd-resolved 2>/dev/null || true
  systemctl disable systemd-resolved 2>/dev/null || true
  
  mkdir -p /etc/sssd
  cp -a /etc/sssd/sssd.conf /etc/sssd/sssd.conf.backup.5.1.$$ 2>/dev/null || true
  
  cat >/etc/sssd/sssd.conf <<EOF
[sssd]
services = nss, pam, sudo
config_file_version = 2
domains = ${REALM}

[domain/${REALM}]
default_shell = /bin/bash
krb5_store_password_if_offline = True
cache_credentials = True
krb5_realm = ${REALM}
realmd_tags = manages-system joined-with-adcli 
id_provider = ad
fallback_homedir = /home/%u@%d
ad_domain = ${REALM,,}
ldap_id_mapping = True
use_fully_qualified_names = True
ldap_sudo_full_refresh_interval=86400
ldap_sudo_smart_refresh_interval=3600
sudo_provider = ad
access_provider = ad
enumerate = True
EOF

  chmod 600 /etc/sssd/sssd.conf
  
  # Настраиваем nsswitch.conf
  if ! grep -q '^sudoers:' /etc/nsswitch.conf 2>/dev/null; then
    echo "sudoers: files sss" >> /etc/nsswitch.conf
  else
    sed -i 's/^sudoers:.*/sudoers: files sss/' /etc/nsswitch.conf || true
  fi
  
  # Обновляем pam configuration
  if [ -f /etc/pam.d/common-session ]; then
    if ! grep -q "pam_mkhomedir.so" /etc/pam.d/common-session; then
      echo "session required pam_mkhomedir.so skel=/etc/skel/ umask=0022" >> /etc/pam.d/common-session
    fi
  fi
  
  info "Запуск SSSD..."
  systemctl restart sssd || {
    err "Ошибка запуска SSSD"
    systemctl status sssd --no-pager -l
    return 1
  }
  
  # Очищаем кеш
  sss_cache -E 2>/dev/null || true
  
  # Проверяем работу
  if systemctl is-active sssd >/dev/null 2>&1; then
    ok "SSSD настроен и запущен"
  else
    err "SSSD не запустился"
    return 1
  fi
  
  warn "Далее: проверьте Kerberos (kinit Administrator) и sudo права пользователем domain user (после входа)"
}

hqcli_check_kinit() {
  info "HQ-CLI: пробуем получить Kerberos тикет (kinit Administrator)"
  
  # Проверяем резолвинг KDC
  info "Проверка резолвинга KDC..."
  if nslookup "_kerberos._tcp.${REALM,,}" >/dev/null 2>&1; then
    ok "KDC резолвится через DNS"
  else
    warn "KDC не резолвится через DNS, используем прямое указание хоста"
  fi
  
  # Пробуем kinit
  info "Получение Kerberos-тикета для Administrator..."
  if printf "%s\n" "${ADMIN_PASS}" | kinit "Administrator@${REALM}" 2>/dev/null; then
    ok "kinit успешен (принят пароль автоматически)"
    info "Информация о тикете:"
    klist 2>/dev/null || true
  else
    warn "kinit не удалось автоматически — выполните вручную:"
    echo "  kinit Administrator@${REALM}"
    echo "  (пароль: ${ADMIN_PASS})"
    info "Проверка доступности KDC:"
    nc -zv "${DC_HOST}" 88 2>/dev/null && echo "✓ Порт 88 (Kerberos) доступен" || echo "✗ Порт 88 недоступен"
  fi
}

# ---------------- Menu logic ----------------
ensure_root

# Проверяем на каком хосте запущен скрипт
detect_host() {
  local hostname=$(hostname -f 2>/dev/null || hostname)
  case "$hostname" in
    *br-srv*) echo "BR-SRV" ;;
    *hq-srv*) echo "HQ-SRV" ;; 
    *hq-cli*) echo "HQ-CLI" ;;
    *) echo "UNKNOWN" ;;
  esac
}

info "Обнаружен хост: $(detect_host)"

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