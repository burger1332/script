#!/bin/bash
# 5_visual.sh - Автоматизация Samba DC с красивой визуализацией шагов

set -e

GREEN="\033[1;32m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RED="\033[1;31m"; RESET="\033[0m"

banner_device(){
  echo -e "${CYAN}=============================="
  echo "[DEVICE] $1"
  echo -e "==============================${RESET}"
}

log_step(){ echo -e "${YELLOW}[STEP $1]${RESET} $2"; }
log_done(){ echo -e "${GREEN}[DONE]${RESET} $1"; }
log_complete(){ echo -e "${CYAN}[COMPLETE]${RESET} $1 полностью настроен"; }

# === BR-SRV ===
setup_br_srv() {
  banner_device "BR-SRV — Samba DC"

  log_step 1 "Настройка resolv.conf (Google DNS)"
  cat >/etc/resolv.conf <<EOF
nameserver 8.8.8.8
EOF
  log_done "resolv.conf"

  log_step 2 "Установка task-samba-dc"
  apt-get update
  apt-get install task-samba-dc -y
  log_done "task-samba-dc"

  log_step 3 "Переключение DNS на HQ-SRV"
  cat >/etc/resolv.conf <<EOF
nameserver 192.168.1.2
EOF
  log_done "resolv.conf обновлён"

  log_step 4 "Удаление smb.conf"
  rm -rf /etc/samba/smb.conf
  log_done "smb.conf удалён"

  log_step 5 "Добавление /etc/hosts"
  echo "192.168.4.2 br-srv.au-team.irpo" >> /etc/hosts
  log_done "hosts"

  log_step 6 "Provision Samba AD DC"
  samba-tool domain provision --realm=AU-TEAM.IRPO --domain=AU-TEAM --server-role=dc --dns-backend=SAMBA_INTERNAL --host-ip=192.168.1.2
  log_done "Provision Samba"

  log_step 7 "Перемещение krb5.conf"
  mv -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
  log_done "krb5.conf"

  log_step 8 "Активация samba"
  systemctl enable samba
  log_done "samba enable"

  log_step 9 "Добавление cron для автозапуска"
  (crontab -l 2>/dev/null; echo "@reboot /bin/systemctl restart network") | crontab -
  (crontab -l 2>/dev/null; echo "@reboot /bin/systemctl restart samba") | crontab -
  log_done "cron"

  log_step 10 "Создание пользователей и группы"
  samba-tool user add user1.hq P@ssw0rd
  samba-tool user add user2.hq P@ssw0rd
  samba-tool user add user3.hq P@ssw0rd
  samba-tool user add user4.hq P@ssw0rd
  samba-tool user add user5.hq P@ssw0rd
  samba-tool group add hq
  samba-tool group addmembers hq user1.hq,user2.hq,user3.hq,user4.hq,user5.hq
  log_done "Пользователи + группа"

  log_step 11 "Установка sudo-samba-schema"
  apt-repo add rpm http://altrepo.ru/local-p10 noarch local-p10
  apt-get update
  apt-get install sudo-samba-schema -y
  sudo-schema-apply
  log_done "sudo-samba-schema"

  log_step 12 "Создание правила sudo"
  create-sudo-rule <<EOF
prava_hq
ALL
/bin/cat
%hq
EOF
  log_done "sudo правило"

  log_step 13 "Импорт пользователей из CSV"
  curl -L https://bit.ly/3C1nEYz > /root/users.zip
  unzip /root/users.zip
  mv /root/Users.csv /opt/Users.csv
  cat >/root/import <<'EOS'
csv_file="/opt/Users.csv"
while IFS=";" read -r firstName lastName role phone ou street zip city country password; do
  if [ "$firstName" == "First Name" ]; then
    continue
  fi
  username="${firstName,,}.${lastName,,}"
  sudo samba-tool user add "$username" 123qweR%
done < "$csv_file"
EOS
  chmod +x /root/import
  bash /root/import
  log_done "CSV пользователи"

  log_complete "BR-SRV"
}

# === HQ-SRV ===
setup_hq_srv() {
  banner_device "HQ-SRV — DNS (dnsmasq)"

  log_step 1 "Добавление записи в dnsmasq.conf"
  echo "server=/au-team.irpo/192.168.4.2" >> /etc/dnsmasq.conf
  log_done "dnsmasq.conf"

  log_step 2 "Перезапуск dnsmasq"
  systemctl restart dnsmasq
  log_done "dnsmasq"

  log_complete "HQ-SRV"
}

# === HQ-CLI ===
setup_hq_cli() {
  banner_device "HQ-CLI — клиент AD"

  log_step 1 "Установка admc"
  apt-get update
  apt-get install admc -y
  log_done "admc"

  log_step 2 "Kinit administrator"
  kinit administrator
  log_done "kinit"

  log_step 3 "Установка sudo + sssd"
  apt-get update
  apt-get install sudo libsss_sudo -y
  log_done "sudo + libsss_sudo"

  log_step 4 "Настройка sssd.conf"
  echo "services = nss, pam, sudo" >> /etc/sssd/sssd.conf
  echo "sudo_provider = ad" >> /etc/sssd/sssd.conf
  log_done "sssd.conf"

  log_step 5 "Правка nsswitch.conf"
  sed -i 's/^sudoers:.*/sudoers: files sss/' /etc/nsswitch.conf
  log_done "nsswitch.conf"

  log_step 6 "Очистка кеша SSSD и рестарт"
  rm -rf /var/lib/sss/db/*
  sss_cache -E
  systemctl restart sssd
  log_done "sssd"

  log_complete "HQ-CLI"
}

# === Меню ===
echo "================================="
echo "Выберите устройство:"
echo " 1) BR-SRV"
echo " 2) HQ-SRV"
echo " 3) HQ-CLI"
echo " 4) Все подряд"
echo " 0) Выход"
echo "================================="
read -rp "Ваш выбор: " CHOICE

case "$CHOICE" in
  1) setup_br_srv ;;
  2) setup_hq_srv ;;
  3) setup_hq_cli ;;
  4) setup_br_srv; setup_hq_srv; setup_hq_cli ;;
  0) exit 0 ;;
  *) echo "Неверный выбор" ;;
esac
