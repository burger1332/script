#!/bin/bash
# full_setup.sh — универсальная автоматизация заданий 1–11
# Автор: "старый сисадмин" :)
# Версия 1.5: Полный код, интерфейсы ens18, стандартный Here-doc

set -euo pipefail

# === Цвета ===
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

log_start() { echo -e "${YELLOW}[START]${RESET} $1"; }
log_done()  { echo -e "${GREEN}[DONE]${RESET} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET} $1"; }

# === Проверка root ===
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}Ошибка:${RESET} скрипт нужно запускать через sudo"
  exit 1
fi

# === Выбор устройства ===
echo "======================================"
echo "Выберите устройство:"
echo " 1) ISP"
echo " 2) HQ-RTR"
echo " 3) BR-RTR"
echo " 4) HQ-SRV"
echo " 5) BR-SRV"
echo " 6) HQ-CLI"
echo " 0) Выйти"
echo "======================================"
read -rp "Ваш выбор: " DEVICE_CHOICE

case "$DEVICE_CHOICE" in
  1) ROLE="ISP" ;;
  2) ROLE="HQ-RTR" ;;
  3) ROLE="BR-RTR" ;;
  4) ROLE="HQ-SRV" ;;
  5) ROLE="BR-SRV" ;;
  6) ROLE="HQ-CLI" ;;
  0) echo "Выход"; exit 0 ;;
  *) echo "Неверный выбор"; exit 1 ;;
esac
echo "»> Устройство выбрано: $ROLE"

# === Выбор задач ===
echo "======================================"
echo "Выберите задачи (несколько через пробел):"
echo " 1) Базовые настройки"
echo " 2) Часовой пояс"
echo " 3) Forward пакетов"
echo " 4) NAT"
echo " 5) VLAN"
echo " 6) GRE"
echo " 7) OSPF"
echo " 8) DHCP"
echo " 9) DNS"
echo "10) Пользователи"
echo "11) SSH"
echo "12) ALL (выполнить все)"
echo " 0) Выйти"
echo "======================================"
read -rp "Ваш выбор: " STEPS

# === Задачи 1–4 ===

setup_base() {
  log_start "Базовые настройки для $ROLE"
  case "$ROLE" in
    HQ-CLI) hostnamectl set-hostname hq-cli.au-team.irpo; hostname "$(hostnamectl --static)" ;;
    HQ-SRV) hostnamectl set-hostname hq-srv.au-team.irpo; hostname "$(hostnamectl --static)" ;;
    ISP)
      hostnamectl set-hostname isp; hostname "$(hostnamectl --static)"
      cat > /etc/network/interfaces <<EOF
auto eth0
 iface eth0 inet dhcp
auto eth1
 iface eth1 inet static
 address 172.16.4.1/28
auto eth2
 iface eth2 inet static
 address 172.16.5.1/28
EOF
      systemctl restart networking ;;
    HQ-RTR)
      hostnamectl set-hostname hq-rtr.au-team.irpo; hostname "$(hostnamectl --static)"
      cat > /etc/network/interfaces <<EOF
auto eth0
 iface eth0 inet static
 address 172.16.4.2/28
 gateway 172.16.4.1
auto eth1
 iface eth1 inet manual
auto eth1.100
 iface eth1.100 inet static
 address 192.168.1.1/26
 vlan-raw-device eth1
auto eth1.200
 iface eth1.200 inet static
 address 192.168.2.1/28
 vlan-raw-device eth1
auto eth1.999
 iface eth1.999 inet static
 address 192.168.3.1/29
 vlan-raw-device eth1
EOF
      systemctl restart networking ;;
    BR-RTR)
      hostnamectl set-hostname br-rtr.au-team.irpo; hostname "$(hostnamectl --static)"
      cat > /etc/network/interfaces <<EOF
auto eth0
 iface eth0 inet static
 address 172.16.5.2/28
 gateway 172.16.5.1
auto eth1
 iface eth1 inet static
 address 192.168.4.1/27
EOF
      systemctl restart networking ;;
    BR-SRV)
      hostnamectl set-hostname br-srv.au-team.irpo; hostname "$(hostnamectl --static)"
      mkdir -p /etc/net/ifaces/ens18
      cat > /etc/net/ifaces/ens18/options <<EOF
TYPE=eth
DISABLED=no
BOOTPROTO=static
NM_CONTROLLED=no
EOF
      echo "192.168.4.2/27" > /etc/net/ifaces/ens18/ipv4address
      echo "default via 192.168.4.1" > /etc/net/ifaces/ens18/ipv4route
      systemctl restart network ;;
  esac
  
  if [[ "$ROLE" == "HQ-RTR" || "$ROLE" == "BR-RTR" || "$ROLE" == "ISP" ]]; then
    if [ -f /etc/iptables/rules.v4 ]; then
      echo "#!/bin/sh" > /etc/network/if-pre-up.d/iptables-load
      echo "iptables-restore < /etc/iptables/rules.v4" » /etc/network/if-pre-up.d/iptables-load
      chmod +x /etc/network/if-pre-up.d/iptables-load
    fi
  fi
  
  log_done "Базовые настройки для $ROLE"
}

setup_timezone() {
  log_start "Часовой пояс для $ROLE"
  timedatectl set-timezone Asia/Yekaterinburg
  log_done "
Часовой пояс для $ROLE"
}

setup_forward() {
  log_start "Forward пакетов для $ROLE"
  if [[ "$ROLE" == "HQ-CLI" ]]; then
    echo "Forward не требуется для $ROLE"
    return
  fi
  echo "net.ipv4.ip_forward=1" » /etc/sysctl.conf
  sysctl -p
  log_done "Forward пакетов включён для $ROLE"
}

setup_nat() {
  log_start "NAT для $ROLE"
  if [[ "$ROLE" == "HQ-CLI" ]]; then
    echo "NAT не требуется для $ROLE"
    return
  fi

  case "$ROLE" in
    ISP)
      iptables -t nat -A POSTROUTING -s 172.16.4.0/28 -o eth0 -j MASQUERADE
      iptables -t nat -A POSTROUTING -s 172.16.5.0/28 -o eth0 -j MASQUERADE ;;
    HQ-RTR)
      iptables -t nat -A POSTROUTING -s 192.168.1.0/26 -o eth0 -j MASQUERADE
      iptables -t nat -A POSTROUTING -s 192.168.2.0/28 -o eth0 -j MASQUERADE
      iptables -t nat -A POSTROUTING -s 192.168.3.0/29 -o eth0 -j MASQUERADE ;;
    BR-RTR)
      iptables -t nat -A POSTROUTING -s 192.168.4.0/27 -o eth0 -j MASQUERADE ;;
  esac

  iptables-save > /root/iptables-nat.rules

  log_start "Создание скрипта автозагрузки NAT"
  cat > /usr/local/bin/load-nat.sh <<EOF
#!/bin/bash
sleep 10
if [ -f /root/iptables-nat.rules ]; then
    iptables-restore < /root/iptables-nat.rules
fi
ROLE=\$(hostname)
case "\$ROLE" in
    isp)
        iptables -t nat -A POSTROUTING -s 172.16.4.0/28 -o eth0 -j MASQUERADE 2>/dev/null || true
        iptables -t nat -A POSTROUTING -s 172.16.5.0/28 -o eth0 -j MASQUERADE 2>/dev/null || true
        ;;
    hq-rtr*)
        iptables -t nat -A POSTROUTING -s 192.168.1.0/26 -o eth0 -j MASQUERADE 2>/dev/null || true
        iptables -t nat -A POSTROUTING -s 192.168.2.0/28 -o eth0 -j MASQUERADE 2>/dev/null || true
        iptables -t nat -A POSTROUTING -s 192.168.3.0/29 -o eth0 -j MASQUERADE 2>/dev/null || true
        ;;
    br-rtr*)
        iptables -t nat -A POSTROUTING -s 192.168.4.0/27 -o eth0 -j MASQUERADE 2>/dev/null || true
        ;;
esac
EOF

  chmod +x /usr/local/bin/load-nat.sh
  (crontab -l 2>/dev/null | grep -v load-nat; echo "@reboot /usr/local/bin/load-nat.sh") | crontab -

  if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/nat-restore.service <<EOF
[Unit]
Description=Restore NAT rules on boot
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/load-nat.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable nat-restore.service
  fi

  if [ -f /etc/rc.local ]; then
    sed -i '/load-nat.sh/d' /etc/rc.local
    sed -i '/^exit 0/i /usr/local/bin/load-nat.sh' /etc/rc.local
  else
    echo -e '#!/bin/bash\n/usr/local/bin/load-nat.sh\nexit 0' > /etc/rc.local
    chmod +x /etc/rc.local
  fi

  log_done "NAT настроен и скрипт автозагрузки создан"
}

setup_vlan() {
  log_start "VLAN для $ROLE"
  case "$ROLE" in
    HQ-SRV)
      IFACE="ens18"
      VLAN_ID=100
      mkdir -p "/etc/net/ifaces/\${IFACE}"
      cat > "/etc/net/ifaces/\${IFACE}/options" <<EOF
TYPE=eth
DISABLED=no
BOOTPROTO=static
EOF
      VLAN_DIR="/etc/net/ifaces/\${IFACE}.\${VLAN_ID}"
      mkdir -p "\$VLAN_DIR"
      cat > "\$VLAN_DIR/options" <<EOF
TYPE=vlan
HOST=\$IFACE
VID=\$VLAN_ID
DISABLED=no
BOOTPROTO=static
EOF
      echo "192.168.1.2/26" > "\$VLAN_DIR/ipv4address"
      echo "default via 192.168.1.1" > "\$VLAN_DIR/ipv4route"
      systemctl restart network ;;
    HQ-CLI)
      IFACE="enp0s3"
      VLAN_ID=200
      VLAN_DIR="/etc/net/ifaces/\${IFACE}.\${VLAN_ID}"
      mkdir -p "\$VLAN_DIR"
      cat > "\$VLAN_DIR/options" <<EOF
TYPE=vlan
HOST=\$IFACE
VID=\$VLAN_ID
DISABLED=no
BOOTPROTO=dhcp
EOF
      systemctl restart network ;;
    *)
      echo "VLAN не требуется для $ROLE" ;;
  esac
  log_done "VLAN для $ROLE"
}

setup_gre() {
  log_start "GRE для $ROLE"
  case "$ROLE" in
    HQ-RTR)
      cat » /etc/network/interfaces <<EOF

auto gre1
iface gre1 inet tunnel
 address 10.10.10.1
 netmask 255.255.255.252
 mode gre
 local 172.16.4.2
 endpoint 172.16.5.2
 ttl 255
EOF
      systemctl restart networking ;;
    BR-RTR)
      cat » /etc/network/interfaces <<EOF
auto gre1
iface gre1 inet tunnel
 address 10.10.10.2
 netmask 255.255.255.252
 mode gre
 local 172.16.5.2
 endpoint 172.16.4.2
 ttl 255
EOF
      systemctl restart networking ;;
    *)
      echo "GRE не требуется для $ROLE" ;;
  esac
  log_done "GRE для $ROLE"
}

setup_ospf() {
  log_start "OSPF для $ROLE"
  if [[ "$ROLE" != "HQ-RTR" && "$ROLE" != "BR-RTR" ]]; then
    echo -e "${YELLOW}OSPF не поддерживается на $ROLE${RESET}"
    return
  fi
  echo "deb [trusted=yes] http://archive.debian.org/debian buster main" » /etc/apt/sources.list
  echo "nameserver 8.8.8.8" > /etc/resolv.conf
  apt-get update
  apt-get install -y frr
  sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons
  systemctl restart frr
  vtysh <<EOF
conf t
router ospf
network 10.10.10.0/30 area 0
EOF
  if [[ "$ROLE" == "HQ-RTR" ]]; then
    vtysh <<EOF
conf t
router ospf
network 192.168.1.0/26 area 0
network 192.168.2.0/28 area 0
network 192.168.3.0/29 area 0
EOF
  else
    vtysh <<EOF
conf t
router ospf
network 192.168.4.0/27 area 0
EOF
  fi
  vtysh <<EOF
conf t
interface gre1
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 P@ssw0rd
exit
exit
wr mem
EOF
  sed -i '/deb \[trusted=yes\] http:\/\/archive.debian.org\/debian buster main/d' /etc/apt/sources.list
  log_done "OSPF успешно настроен на $ROLE"
}

setup_dhcp() {
  log_start "DHCP для $ROLE"
  if [[ "$ROLE" == "HQ-RTR" ]]; then
    apt-get install -y dnsmasq
    cat > /etc/dnsmasq.conf <<EOF
no-resolv
dhcp-range=192.168.2.2,192.168.2.14,9999h
dhcp-option=3,192.168.2.1
dhcp-option=6,192.168.1.2
interface=eth1.200
EOF
    systemctl restart dnsmasq
  else
    echo "DHCP не требуется для $ROLE"
  fi
  log_done "DHCP для $ROLE"
}

setup_dns() {
  log_start "DNS для $ROLE"
  echo "nameserver 8.8.8.8" > /etc/resolv.conf
  apt-get update
  if [[ "$ROLE" == "HQ-SRV" ]]; then
    apt-get install -y dnsmasq
    cat > /etc/dnsmasq.conf <<EOF
no-resolv
domain=au-team.irpo
server=8.8.8.8
interface=*
address=/hq-rtr.au-team.irpo/192.168.1.1
address=/br-rtr.au-team.irpo/192.168.4.1
address=/hq-srv.au-team.irpo/192.168.1.2
address=/hq-cli.au-team.irpo/192.168.2.11
address=/br-srv.au-team.irpo/192.168.4.2
EOF
    systemctl restart dnsmasq
  else
    echo "DNS-сервер не требуется для $ROLE"
  fi
  log_done "DNS для $ROLE"
}

setup_users() {
  log_start "Пользователи для $ROLE"
  case "$ROLE" in
    HQ-SRV|BR-SRV)
      useradd sshuser -u 1010 || true
      echo "sshuser:P@ssw0rd" | chpasswd
      usermod -aG wheel sshuser ;;
    HQ-RTR|BR-RTR)
      useradd net_admin -m || true
      echo "net_admin:P@\$\$word" | chpasswd
      echo "net_admin ALL=(ALL:ALL) NOPASSWD: ALL" » /etc/sudoers ;;
    *)
      echo "Пользователи не требуются для $ROLE" ;;
  esac
  log_done "Пользователи для $ROLE"
}

setup_ssh() {
  log_start "SSH для $ROLE"
  if [[ "$ROLE" == "HQ-SRV" || "$ROLE" == "BR-SRV" ]]; then
    apt-get install -y openssh-common openssh-server
    SSHD_CONFIG="/etc/openssh/sshd_config"
    mkdir -p /etc/openssh
    cat > "$SSHD_CONFIG" <<EOF
Port 2024
Protocol 2
PermitRootLogin no
MaxAuthTries 2
AllowUsers sshuser
Banner /root/banner
PasswordAuthentication yes
EOF
    echo "Authorized access only" > /root/banner
    systemctl enable sshd
    systemctl restart sshd
  elif [[ "$ROLE" == "HQ-CLI" ]]; then
    echo "На HQ-CLI используйте: ssh sshuser@192.168.1.2 -p 2024"
  fi
  log_done "SSH для $ROLE"
}

run_step() {
  case "$1" in
    1) setup_base ;;
    2) setup_timezone ;;
    3) setup_forward ;;
    4) setup_nat ;;
    5) setup_vlan ;;
    6) setup_gre ;;
    7) setup_ospf ;;
    8) setup_dhcp ;;
    9) setup_dns ;;
    10) setup_users ;;
    11) setup_ssh ;;
    12) setup_base; setup_timezone; setup_forward; setup_nat; setup_vlan; setup_gre; setup_ospf; setup_dhcp; setup_dns; setup_users; setup_ssh ;;
  esac
}

for STEP in $STEPS; do run_step "$STEP"; done
chattr -i /etc/resolv.conf 2>/dev/null || true
echo -e "${GREEN}[FINISHED]${RESET} Выполнено для $ROLE"
exec bash
