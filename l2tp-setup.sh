#!/bin/bash
# ============================================================
#  L2TP/IPsec VPN Setup — Ubuntu 24.04 / AlmaLinux 9
#  - IPsec (strongSwan) + L2TP (xl2tpd) + PPP
#  - NO defaultroute (SSH не отвалится)
#  - Автоматический проброс маршрутов через ppp0
#  - Режимы: install / uninstall
#
#  Использование:
#    sudo ./l2tp-setup.sh            # интерактивное меню
#    sudo ./l2tp-setup.sh install    # сразу установка
#    sudo ./l2tp-setup.sh uninstall  # удаление
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
header()  { echo -e "\n${BOLD}=== $1 ===${NC}"; }

MARKER_DIR="/etc/l2tp-setup"
MARKER_FILE="${MARKER_DIR}/installed.conf"

# ────────────────────────────────────────────────
# Определение ОС
# ────────────────────────────────────────────────
detect_os() {
    [[ ! -f /etc/os-release ]] && error "Не удалось определить ОС"
    . /etc/os-release
    OS_ID="$ID"
    OS_VERSION="$VERSION_ID"

    case "$OS_ID" in
        ubuntu)
            OS_FAMILY="debian"
            IPSEC_CONF="/etc/ipsec.conf"
            IPSEC_SECRETS="/etc/ipsec.secrets"
            STRONGSWAN_SERVICE="strongswan-starter"
            [[ "$OS_VERSION" != "24.04" ]] && warn "Тестировалось на Ubuntu 24.04. Ваша: $OS_VERSION"
            ;;
        almalinux|rocky|rhel|centos)
            OS_FAMILY="rhel"
            IPSEC_CONF="/etc/strongswan/ipsec.conf"
            IPSEC_SECRETS="/etc/strongswan/ipsec.secrets"
            STRONGSWAN_SERVICE="strongswan"
            MAJOR_VER="${OS_VERSION%%.*}"
            [[ "$MAJOR_VER" != "9" ]] && warn "Тестировалось на EL 9.x. Ваша: $OS_VERSION"
            ;;
        *)
            error "Неподдерживаемая ОС: $OS_ID (поддерживаются: ubuntu, almalinux, rocky, rhel)"
            ;;
    esac

    info "ОС: $PRETTY_NAME ($OS_FAMILY)"
}

install_packages() {
    header "Установка пакетов"
    if [[ "$OS_FAMILY" == "debian" ]]; then
        apt-get update
        apt-get install -y xl2tpd strongswan libcharon-extra-plugins ppp
    else
        info "Подключаем EPEL репозиторий..."
        dnf install -y epel-release

        info "Устанавливаем kernel-modules-extra (содержит l2tp_ppp)..."
        dnf install -y kernel-modules-extra

        info "Устанавливаем VPN пакеты..."
        dnf install -y xl2tpd strongswan ppp
        mkdir -p /var/run/xl2tpd

        # Проверка что не контейнер (в LXC/OpenVZ модули не загружаются)
        VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "unknown")
        if [[ "$VIRT_TYPE" == "lxc" || "$VIRT_TYPE" == "openvz" || "$VIRT_TYPE" == "docker" ]]; then
            warn "Обнаружен контейнер ($VIRT_TYPE) — загрузка kernel-модулей невозможна!"
            warn "L2TP не будет работать на этом типе виртуализации."
            warn "Нужен KVM, VMware или bare metal."
            read -rp "Всё равно продолжить? [y/N]: " FORCE
            [[ "$FORCE" != "y" && "$FORCE" != "Y" ]] && exit 1
        fi

        # Загружаем l2tp_ppp заранее, чтобы xl2tpd стартовал без ошибок
        info "Загружаем kernel-модуль l2tp_ppp..."
        if modprobe l2tp_ppp 2>/dev/null; then
            success "Модуль l2tp_ppp загружен"
            # Автозагрузка при старте системы
            echo "l2tp_ppp" > /etc/modules-load.d/l2tp.conf
        else
            warn "Не удалось загрузить l2tp_ppp. Возможные причины:"
            warn "  - Ядро не содержит модуль (нужна перезагрузка после kernel-modules-extra)"
            warn "  - Это контейнер без доступа к модулям"
            warn "  Попробуйте: sudo reboot, затем sudo modprobe l2tp_ppp"
        fi
    fi
    success "Пакеты установлены"
}

# ────────────────────────────────────────────────
# Стартовые проверки
# ────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Запустите скрипт от root: sudo $0"

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║       L2TP/IPsec VPN — Setup Tool            ║"
echo "║     Ubuntu 24.04 / AlmaLinux 9               ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ────────────────────────────────────────────────
# Режим работы
# ────────────────────────────────────────────────
MODE="${1:-}"
if [[ -z "$MODE" ]]; then
    echo "  1) Установить VPN"
    echo "  2) Удалить VPN (все настройки и пакеты)"
    echo "  3) Выход"
    echo
    read -rp "Выберите действие [1-3]: " CHOICE
    case "$CHOICE" in
        1) MODE="install" ;;
        2) MODE="uninstall" ;;
        *) echo "Выход."; exit 0 ;;
    esac
fi

detect_os

# ============================================================
#                         UNINSTALL
# ============================================================
if [[ "$MODE" == "uninstall" ]]; then
    header "Удаление L2TP VPN"

    if [[ -f "$MARKER_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$MARKER_FILE"
        info "Найдена установка: $VPN_NAME (сервер $VPN_SERVER)"
    else
        warn "Маркер установки не найден — удаление по имени вручную"
        read -rp "Имя VPN подключения для удаления [myvpn]: " VPN_NAME_INPUT
        VPN_NAME="${VPN_NAME_INPUT:-myvpn}"
    fi

    read -rp "Продолжить удаление? [y/N]: " CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && echo "Отмена." && exit 0

    info "Останавливаем VPN если подключён..."
    if [[ -e /var/run/xl2tpd/l2tp-control ]]; then
        echo "d $VPN_NAME" > /var/run/xl2tpd/l2tp-control 2>/dev/null || true
        sleep 2
    fi
    ipsec down "$VPN_NAME" 2>/dev/null || true

    info "Останавливаем и отключаем службы..."
    systemctl stop xl2tpd 2>/dev/null || true
    systemctl stop "$STRONGSWAN_SERVICE" 2>/dev/null || true
    systemctl disable xl2tpd 2>/dev/null || true
    systemctl disable "$STRONGSWAN_SERVICE" 2>/dev/null || true

    info "Удаляем конфиги..."
    rm -f "$IPSEC_CONF"
    rm -f "$IPSEC_SECRETS"
    rm -f "/etc/strongswan/swanctl/conf.d/${VPN_NAME}.conf"
    rm -f /etc/xl2tpd/xl2tpd.conf
    [[ -f /etc/xl2tpd/xl2tpd.conf.bak ]] && mv /etc/xl2tpd/xl2tpd.conf.bak /etc/xl2tpd/xl2tpd.conf
    rm -f "/etc/ppp/peers/${VPN_NAME}"
    rm -f "/etc/ppp/ip-up.d/${VPN_NAME}-routes"
    rm -f "/etc/ppp/ip-down.d/${VPN_NAME}-routes"

    info "Удаляем управляющие команды..."
    rm -f /usr/local/bin/vpn-up /usr/local/bin/vpn-down /usr/local/bin/vpn-status
    rm -f /usr/bin/vpn-up /usr/bin/vpn-down /usr/bin/vpn-status

    # Автозагрузка kernel-модуля (только для RHEL)
    rm -f /etc/modules-load.d/l2tp.conf

    rm -rf "$MARKER_DIR"

    echo
    read -rp "Удалить пакеты (xl2tpd, strongswan, ppp)? [y/N]: " REMOVE_PKG
    if [[ "$REMOVE_PKG" == "y" || "$REMOVE_PKG" == "Y" ]]; then
        info "Удаляем пакеты..."
        if [[ "$OS_FAMILY" == "debian" ]]; then
            apt-get remove --purge -y xl2tpd strongswan libcharon-extra-plugins
            apt-get autoremove -y
        else
            dnf remove -y xl2tpd strongswan
        fi
        success "Пакеты удалены"
    else
        info "Пакеты оставлены"
    fi

    echo
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║          Удаление завершено!                 ║${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
    echo
    exit 0
fi

# ============================================================
#                          INSTALL
# ============================================================

# Предупреждение если уже установлен
if [[ -f "$MARKER_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$MARKER_FILE"
    warn "Обнаружена существующая установка: $VPN_NAME"
    read -rp "Продолжить и перезаписать? [y/N]: " OVERWRITE
    [[ "$OVERWRITE" != "y" && "$OVERWRITE" != "Y" ]] && echo "Отмена." && exit 0
    unset VPN_NAME VPN_SERVER VPN_ROUTES
fi

header "Параметры подключения"

read -rp "  VPN-сервер (IP или домен): " VPN_SERVER
[[ -z "$VPN_SERVER" ]] && error "Сервер не указан"

read -rp "  Имя пользователя: " VPN_USER
[[ -z "$VPN_USER" ]] && error "Пользователь не указан"

# Проверка на не-ASCII символы (кириллица легко путается с латиницей)
if [[ "$VPN_USER" =~ [^[:print:]] || "$VPN_USER" != "$(echo -n "$VPN_USER" | LC_ALL=C tr -cd '[:print:]')" ]]; then
    warn "Логин содержит не-ASCII символы! Возможно кириллица вместо латиницы."
    warn "Проверьте каждую букву: e→е, c→с, o→о, p→р, a→а, x→х легко спутать."
    read -rp "Продолжить с этим логином? [y/N]: " FORCE_USER
    [[ "$FORCE_USER" != "y" && "$FORCE_USER" != "Y" ]] && error "Введите логин заново"
fi

read -rsp "  Пароль пользователя: " VPN_PASSWORD; echo
[[ -z "$VPN_PASSWORD" ]] && error "Пароль не указан"

read -rsp "  Pre-shared key (IPsec PSK): " VPN_PSK; echo
[[ -z "$VPN_PSK" ]] && error "PSK не указан"

echo
echo -e "  ${BOLD}Маршруты через VPN${NC} (через запятую: 192.168.11.0/24,10.10.0.0/16)"
read -rp "  Сети [по умолчанию: 192.168.11.0/24]: " VPN_ROUTES_INPUT
VPN_ROUTES="${VPN_ROUTES_INPUT:-192.168.11.0/24}"

read -rp "  Имя подключения [по умолчанию: myvpn]: " VPN_NAME_INPUT
VPN_NAME="${VPN_NAME_INPUT:-myvpn}"

echo
info "Сервер:       $VPN_SERVER"
info "Пользователь: $VPN_USER"
info "PSK:          ****"
info "Маршруты:     $VPN_ROUTES"
info "Имя VPN:      $VPN_NAME"
echo
read -rp "Продолжить установку? [y/N]: " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && echo "Отмена." && exit 0

install_packages

# ────────────────────────────────────────────────
# IPsec
# ────────────────────────────────────────────────
header "Настройка IPsec"

if [[ "$OS_FAMILY" == "debian" ]]; then
    # Ubuntu: legacy ipsec.conf + ipsec starter
    mkdir -p "$(dirname "$IPSEC_CONF")"

    cat > "$IPSEC_CONF" <<EOF
config setup
    charondebug="ike 1, knl 1, cfg 0"

conn ${VPN_NAME}
    authby=secret
    auto=add
    keyexchange=ikev1
    type=transport
    left=%defaultroute
    leftprotoport=17/1701
    rightprotoport=17/1701
    right=${VPN_SERVER}
    ike=aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024
    esp=aes256-sha1,aes128-sha1,3des-sha1
    ikelifetime=8h
    keylife=1h
    dpdaction=clear
    dpddelay=30s
    dpdtimeout=120s
EOF

    cat > "$IPSEC_SECRETS" <<EOF
%any ${VPN_SERVER} : PSK "${VPN_PSK}"
EOF
    chmod 600 "$IPSEC_SECRETS"
    success "IPsec настроен: $IPSEC_CONF"
else
    # AlmaLinux 9: swanctl (EPEL strongswan не содержит legacy ipsec starter)
    SWANCTL_DIR="/etc/strongswan/swanctl/conf.d"
    mkdir -p "$SWANCTL_DIR"

    cat > "${SWANCTL_DIR}/${VPN_NAME}.conf" <<EOF
connections {
    ${VPN_NAME} {
        version = 1
        local_addrs = %any
        remote_addrs = ${VPN_SERVER}
        proposals = aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024,default

        local {
            auth = psk
        }
        remote {
            auth = psk
        }

        children {
            ${VPN_NAME} {
                mode = transport
                local_ts  = dynamic[udp/1701]
                remote_ts = dynamic[udp/1701]
                esp_proposals = aes256-sha1,aes128-sha1,3des-sha1,default
                start_action = none
                dpd_action = clear
            }
        }
    }
}

secrets {
    ike-${VPN_NAME} {
        id-1 = ${VPN_SERVER}
        secret = "${VPN_PSK}"
    }
}
EOF
    chmod 600 "${SWANCTL_DIR}/${VPN_NAME}.conf"
    success "IPsec настроен (swanctl): ${SWANCTL_DIR}/${VPN_NAME}.conf"
fi

# ────────────────────────────────────────────────
# xl2tpd
# ────────────────────────────────────────────────
header "Настройка xl2tpd"
[[ -f /etc/xl2tpd/xl2tpd.conf && ! -f /etc/xl2tpd/xl2tpd.conf.bak ]] && \
    cp /etc/xl2tpd/xl2tpd.conf /etc/xl2tpd/xl2tpd.conf.bak
mkdir -p /etc/xl2tpd

cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701

[lac ${VPN_NAME}]
lns = ${VPN_SERVER}
ppp debug = no
pppoptfile = /etc/ppp/peers/${VPN_NAME}
length bit = yes
EOF
success "xl2tpd настроен"

# ────────────────────────────────────────────────
# PPP
# ────────────────────────────────────────────────
header "Настройка PPP"
mkdir -p /etc/ppp/peers /etc/ppp/ip-up.d /etc/ppp/ip-down.d

cat > "/etc/ppp/peers/${VPN_NAME}" <<EOF
ipcp-accept-local
ipcp-accept-remote
refuse-eap
require-mschap-v2
noccp
noauth
mtu 1410
mru 1410
# defaultroute  ← намеренно отключено, SSH не отвалится
# usepeerdns    ← отключено, системный DNS не меняется
# Keepalive — без этого PPP отваливается по тишине
lcp-echo-interval 30
lcp-echo-failure 4
# Авто-переподключение при разрыве
persist
maxfail 0
holdoff 10
debug
connect-delay 5000
name ${VPN_USER}
password ${VPN_PASSWORD}
EOF
chmod 600 "/etc/ppp/peers/${VPN_NAME}"
success "PPP настроен (defaultroute отключён)"

# ────────────────────────────────────────────────
# Авто-маршруты
# ────────────────────────────────────────────────
header "Настройка автоматических маршрутов"

ROUTES_SCRIPT="/etc/ppp/ip-up.d/${VPN_NAME}-routes"
cat > "$ROUTES_SCRIPT" <<SCRIPT_EOF
#!/bin/bash
PPP_IFACE="\$1"
sleep 2
ROUTES="${VPN_ROUTES}"
IFS=',' read -ra ROUTE_LIST <<< "\$ROUTES"
for ROUTE in "\${ROUTE_LIST[@]}"; do
    ROUTE="\$(echo \$ROUTE | tr -d ' ')"
    if ip route add "\$ROUTE" dev "\$PPP_IFACE" 2>/dev/null; then
        logger "VPN ${VPN_NAME}: маршрут \$ROUTE добавлен через \$PPP_IFACE"
    else
        logger "VPN ${VPN_NAME}: маршрут \$ROUTE уже существует или ошибка"
    fi
done
SCRIPT_EOF
chmod +x "$ROUTES_SCRIPT"

DOWN_SCRIPT="/etc/ppp/ip-down.d/${VPN_NAME}-routes"
cat > "$DOWN_SCRIPT" <<SCRIPT_EOF
#!/bin/bash
ROUTES="${VPN_ROUTES}"
IFS=',' read -ra ROUTE_LIST <<< "\$ROUTES"
for ROUTE in "\${ROUTE_LIST[@]}"; do
    ROUTE="\$(echo \$ROUTE | tr -d ' ')"
    ip route del "\$ROUTE" 2>/dev/null || true
    logger "VPN ${VPN_NAME}: маршрут \$ROUTE удалён"
done
SCRIPT_EOF
chmod +x "$DOWN_SCRIPT"
success "Маршруты настроены: $VPN_ROUTES"

# ────────────────────────────────────────────────
# Управляющие команды
# ────────────────────────────────────────────────
header "Создание управляющих команд"

# На RHEL-семействе /usr/local/bin не в sudo secure_path, используем /usr/bin
if [[ "$OS_FAMILY" == "rhel" ]]; then
    BIN_DIR="/usr/bin"
else
    BIN_DIR="/usr/local/bin"
fi

cat > "$BIN_DIR/vpn-up" <<CMD_EOF
#!/bin/bash
VPN_NAME="${VPN_NAME}"
STRONGSWAN_SERVICE="${STRONGSWAN_SERVICE}"
OS_FAMILY="${OS_FAMILY}"

echo "Запуск IPsec..."
systemctl start "\$STRONGSWAN_SERVICE"
sleep 1

echo "Поднимаем IPsec туннель..."
if [[ "\$OS_FAMILY" == "debian" ]]; then
    ipsec up "\$VPN_NAME"
else
    # AlmaLinux: swanctl
    # Сначала терминируем старую SA если висит
    swanctl --terminate --ike "\$VPN_NAME" --timeout 3000 >/dev/null 2>&1 || true
    # Перезагружаем конфиг
    swanctl --load-all 2>&1 | grep -vE "^(plugin|no files|no authorities|no pools)" || true
    # Инициируем с таймаутом 15 секунд
    swanctl --initiate --child "\$VPN_NAME" --ike "\$VPN_NAME" --timeout 15000 2>&1 \
        | grep -vE "^(plugin 'sqlite'|^\s*$)" || true
fi
sleep 2

echo "Подключаем L2TP..."
mkdir -p /var/run/xl2tpd
systemctl start xl2tpd
sleep 1
echo "c \$VPN_NAME" > /var/run/xl2tpd/l2tp-control

echo "Ожидаем ppp0..."
PPP_OK=0
for i in \$(seq 1 15); do
    if ip link show ppp0 &>/dev/null; then
        # Проверяем что интерфейс стабилен — у него есть IP адрес
        if ip -4 addr show ppp0 2>/dev/null | grep -q "inet "; then
            # Двойная проверка — подождать и убедиться что не пропал
            sleep 2
            if ip link show ppp0 &>/dev/null && ip -4 addr show ppp0 | grep -q "inet "; then
                PPP_OK=1
                break
            fi
        fi
    fi
    echo -n "."
    sleep 1
done

if [[ "\$PPP_OK" == "1" ]]; then
    echo ""
    echo -e "\033[0;32m[OK]\033[0m VPN подключён!"
    ip addr show ppp0 | grep "inet "
    echo ""
    echo "Маршруты:"
    ip route show dev ppp0
    exit 0
fi

echo ""
echo -e "\033[0;31m[ERROR]\033[0m ppp0 не поднялся или упал. Логи (последние 30 строк):"
journalctl -u xl2tpd -n 30 --no-pager | grep -E "pppd|xl2tpd|CHAP|auth|failed" | tail -20
echo ""
echo "Полные логи:"
echo "  journalctl -u xl2tpd -n 40"
echo "  journalctl -u \$STRONGSWAN_SERVICE -n 40"
exit 1
CMD_EOF
chmod +x "$BIN_DIR/vpn-up"

cat > "$BIN_DIR/vpn-down" <<CMD_EOF
#!/bin/bash
VPN_NAME="${VPN_NAME}"
OS_FAMILY="${OS_FAMILY}"

echo "Отключаем L2TP..."
echo "d \$VPN_NAME" > /var/run/xl2tpd/l2tp-control 2>/dev/null || true
sleep 2

echo "Опускаем IPsec..."
if [[ "\$OS_FAMILY" == "debian" ]]; then
    ipsec down "\$VPN_NAME" 2>/dev/null || true
else
    swanctl --terminate --ike "\$VPN_NAME" 2>/dev/null || true
fi

echo -e "\033[0;32m[OK]\033[0m VPN отключён."
CMD_EOF
chmod +x "$BIN_DIR/vpn-down"

cat > "$BIN_DIR/vpn-status" <<CMD_EOF
#!/bin/bash
VPN_NAME="${VPN_NAME}"
OS_FAMILY="${OS_FAMILY}"

echo "=== IPsec статус ==="
if [[ "\$OS_FAMILY" == "debian" ]]; then
    ipsec status "\$VPN_NAME" 2>/dev/null || echo "IPsec не активен"
else
    swanctl --list-sas 2>/dev/null || echo "IPsec не активен"
fi

echo ""
echo "=== PPP интерфейс ==="
if ip link show ppp0 &>/dev/null; then
    ip addr show ppp0
    echo ""
    echo "=== Маршруты через ppp0 ==="
    ip route show dev ppp0
else
    echo "ppp0 не активен — VPN не подключён"
fi

echo ""
echo "=== Внешний IP ==="
curl -s --max-time 5 ifconfig.me && echo
CMD_EOF
chmod +x "$BIN_DIR/vpn-status"

success "Команды созданы в $BIN_DIR: vpn-up, vpn-down, vpn-status"

# ────────────────────────────────────────────────
# Маркер для uninstall
# ────────────────────────────────────────────────
mkdir -p "$MARKER_DIR"
cat > "$MARKER_FILE" <<EOF
VPN_NAME="${VPN_NAME}"
VPN_SERVER="${VPN_SERVER}"
VPN_ROUTES="${VPN_ROUTES}"
OS_FAMILY="${OS_FAMILY}"
STRONGSWAN_SERVICE="${STRONGSWAN_SERVICE}"
IPSEC_CONF="${IPSEC_CONF}"
IPSEC_SECRETS="${IPSEC_SECRETS}"
INSTALLED_AT="$(date -Iseconds)"
EOF
chmod 600 "$MARKER_FILE"

# ────────────────────────────────────────────────
# Запуск служб
# ────────────────────────────────────────────────
header "Запуск служб"
systemctl enable "$STRONGSWAN_SERVICE"
systemctl enable xl2tpd
systemctl restart "$STRONGSWAN_SERVICE"
systemctl restart xl2tpd
success "Службы запущены"

# ────────────────────────────────────────────────
# Итог
# ────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║           Установка завершена!               ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo
echo -e "  ${BOLD}Подключиться:${NC}    vpn-up"
echo -e "  ${BOLD}Отключиться:${NC}     vpn-down"
echo -e "  ${BOLD}Статус:${NC}          vpn-status"
echo -e "  ${BOLD}Удалить всё:${NC}     sudo $0 uninstall"
echo
echo -e "  ${BOLD}Маршруты через VPN:${NC}"
IFS=',' read -ra ROUTE_LIST <<< "$VPN_ROUTES"
for ROUTE in "${ROUTE_LIST[@]}"; do
    echo -e "    → ${ROUTE// /}"
done
echo
echo -e "  ${YELLOW}defaultroute отключён — SSH соединение не пострадает${NC}"
echo
echo -e "  Логи:  journalctl -u xl2tpd -f"
echo -e "         journalctl -u $STRONGSWAN_SERVICE -f"
echo
