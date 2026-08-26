#!/bin/bash
# ============================================================================
# CrystalDiskInfo CLI — Финальная версия с умной установкой зависимостей
# ============================================================================

if [ "$EUID" -ne 0 ] && [ -x /usr/bin/sudo ]; then
    echo "Запуск с правами root..."
    exec sudo "$0" "$@"
fi

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
GRAY=$'\033[0;90m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

CIRCLE_GOOD="${GREEN}[+]${RESET}"
CIRCLE_WARN="${YELLOW}[!]${RESET}"
CIRCLE_BAD="${RED}[X]${RESET}"
CIRCLE_UNKNOWN="${GRAY}[?]${RESET}"

check_dependencies() {
    local missing=()
    
    if ! command -v smartctl &>/dev/null; then missing+=("smartctl (smartmontools)"); fi
    if ! command -v lsblk &>/dev/null; then missing+=("lsblk (util-linux)"); fi
    if ! command -v column &>/dev/null; then missing+=("column (util-linux)"); fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Ошибка: Не установлены необходимые пакеты:${RESET}"
        for pkg in "${missing[@]}"; do echo "  - $pkg"; done
        echo ""
        echo "Установка: sudo apt install smartmontools util-linux (или аналог для вашего дистрибутива)"
        exit 1
    fi
}

# ============================================================================
# Умная проверка и установка xclip ТОЛЬКО при генерации отчёта
# ============================================================================
ensure_clipboard_tool() {
    if ! command -v xclip &>/dev/null && ! command -v xsel &>/dev/null; then
        echo -e "${YELLOW}⚠️ Для копирования ссылки отчёта в буфер обмена требуется утилита 'xclip' или 'xsel'.${RESET}"
        echo -n "Установить 'xclip' сейчас? (y/n): "
        read -r install_choice
        
        if [[ "$install_choice" =~ ^[YyДyд]$ ]]; then
            echo "⏳ Установка..."
            if command -v apt &>/dev/null; then
                sudo apt update -qq && sudo apt install -y xclip
            elif command -v dnf &>/dev/null; then
                sudo dnf install -y xclip
            elif command -v pacman &>/dev/null; then
                sudo pacman -S --noconfirm xclip
            elif command -v zypper &>/dev/null; then
                sudo zypper install -y xclip
            else
                echo -e "${RED}❌ Не удалось определить менеджер пакетов. Установите xclip вручную.${RESET}"
                return 1
            fi
            
            if command -v xclip &>/dev/null || command -v xsel &>/dev/null; then
                echo -e "${GREEN}✅ Утилита успешно установлена!${RESET}"
                return 0
            else
                echo -e "${RED}❌ Ошибка при установке.${RESET}"
                return 1
            fi
        else
            echo "Пропуск установки. Ссылка не будет автоматически скопирована в буфер обмена."
            return 1
        fi
    fi
    return 0
}

get_disk_list() {
    DISKS=()
    DISK_INFO=()
    
    while IFS= read -r line; do
        local dev=$(echo "$line" | awk '{print $1}')
        local model=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ *//')
        [[ "$dev" =~ ^(loop|ram|dm) ]] && continue
        DISKS+=("$dev")
        DISK_INFO+=("$model")
    done < <(lsblk -d -n -o NAME,MODEL 2>/dev/null | grep -E '^(sd|nvme|hd)')
    
    if [ ${#DISKS[@]} -eq 0 ]; then
        while IFS= read -r line; do
            local dev=$(echo "$line" | awk '{print $1}')
            local type=$(echo "$line" | awk '{print $3}' | tr -d ',')
            DISKS+=("$dev")
            DISK_INFO+=("[$type]")
        done < <(smartctl --scan 2>/dev/null | grep -E '/dev/(sd|nvme)')
    fi
}

get_smart_data() {
    local device=$1
    SMART_DATA=""
    IS_NVME=false
    SMART_TYPE="sata"
    
    if [[ "$device" =~ nvme ]]; then
        IS_NVME=true
        if command -v nvme &>/dev/null; then
            SMART_DATA=$(nvme smart-log "/dev/$device" 2>/dev/null || echo "")
            SMART_TYPE="nvme"
        else
            SMART_DATA=$(smartctl -A "/dev/$device" 2>/dev/null || echo "")
            SMART_TYPE="nvme-smartctl"
        fi
    else
        SMART_DATA=$(smartctl -A "/dev/$device" 2>/dev/null || echo "")
    fi
}

parse_disk_info() {
    local device=$1
    local full_info=$(smartctl -i "/dev/$device" 2>/dev/null || echo "")
    
    DISK_MODEL=$(echo "$full_info" | grep -i "Model Family\|Model Number\|Device Model" | head -1 | sed 's/.*: //')
    [ -z "$DISK_MODEL" ] && DISK_MODEL="Unknown"
    
    DISK_SERIAL=$(echo "$full_info" | grep -i "Serial Number" | sed 's/.*: //')
    [ -z "$DISK_SERIAL" ] && DISK_SERIAL="N/A"
    
    DISK_FIRMWARE=$(echo "$full_info" | grep -i "Firmware Version" | sed 's/.*: //')
    [ -z "$DISK_FIRMWARE" ] && DISK_FIRMWARE="N/A"
    
    if $IS_NVME; then
        DISK_INTERFACE="NVMe"
    else
        local sata_ver=$(echo "$full_info" | grep -i "SATA Version" | sed 's/.*: //')
        DISK_INTERFACE="${sata_ver:-SATA}"
    fi
    
    local size=$(lsblk -d -n -o SIZE "/dev/$device" 2>/dev/null | tr -d ' ')
    DISK_SIZE="${size:-N/A}"
    
    parse_temperature
    parse_power_on_hours
    parse_power_cycles
}

parse_temperature() {
    DISK_TEMP="N/A"
    if $IS_NVME; then
        if [ "$SMART_TYPE" = "nvme" ]; then
            DISK_TEMP=$(echo "$SMART_DATA" | grep -i "temperature" | head -1 | awk '{print $2}' | sed 's/°C//')
            DISK_TEMP="${DISK_TEMP}°C"
        else
            DISK_TEMP=$(echo "$SMART_DATA" | grep -i "Temperature" | head -1 | awk '{print $2}')
            DISK_TEMP="${DISK_TEMP}°C"
        fi
    else
        local temp_raw=$(echo "$SMART_DATA" | grep -E "^194 " | awk '{print $10}')
        [ -n "$temp_raw" ] && DISK_TEMP="$((temp_raw & 0xFF))°C"
    fi
}

parse_power_on_hours() {
    DISK_HOURS="N/A"
    if $IS_NVME; then
        if [ "$SMART_TYPE" = "nvme" ]; then
            local hours=$(echo "$SMART_DATA" | grep -i "power_on_hours" | awk '{print $2}')
            DISK_HOURS="${hours} ч"
        else
            local hours=$(echo "$SMART_DATA" | grep -i "Power On Hours" | awk '{print $NF}')
            DISK_HOURS="${hours} ч"
        fi
    else
        local hours=$(echo "$SMART_DATA" | grep -E "^  9 " | awk '{print $10}')
        [ -n "$hours" ] && DISK_HOURS="${hours} ч"
    fi
}

parse_power_cycles() {
    DISK_CYCLES="N/A"
    if $IS_NVME; then
        if [ "$SMART_TYPE" = "nvme" ]; then
            local cycles=$(echo "$SMART_DATA" | grep -i "power_cycles" | awk '{print $2}')
            DISK_CYCLES="${cycles} раз"
        else
            local cycles=$(echo "$SMART_DATA" | grep -i "Power Cycles" | awk '{print $NF}')
            DISK_CYCLES="${cycles} раз"
        fi
    else
        local cycles=$(echo "$SMART_DATA" | grep -E "^ 12 " | awk '{print $10}')
        [ -n "$cycles" ] && DISK_CYCLES="${cycles} раз"
    fi
}

get_disk_health() {
    local health="GOOD"
    local health_percent=100
    
    if $IS_NVME; then
        if [ "$SMART_TYPE" = "nvme" ]; then
            local pct_used=$(echo "$SMART_DATA" | grep -i "percentage_used" | awk '{print $2}')
            [ -n "$pct_used" ] && health_percent=$((100 - pct_used))
        fi
    else
        local life_left=$(echo "$SMART_DATA" | grep -E "^(231|233) " | awk '{print $4}')
        [ -n "$life_left" ] && health_percent=$life_left
        
        local reallocated=$(echo "$SMART_DATA" | grep -E "^  5 " | awk '{print $10}')
        [ -n "$reallocated" ] && [ "$reallocated" -gt 0 ] 2>/dev/null && health="WARNING"
        
        local unstable=$(echo "$SMART_DATA" | grep -E "^197 " | awk '{print $10}')
        [ -n "$unstable" ] && [ "$unstable" -gt 0 ] 2>/dev/null && health="WARNING"
    fi
    
    [ "$health_percent" -lt 10 ] && health="BAD"
    [ "$health_percent" -lt 50 ] && [ "$health" != "BAD" ] && health="WARNING"
    
    DISK_HEALTH=$health
    DISK_HEALTH_PERCENT=$health_percent
}

parse_smart_attributes() {
    SMART_ATTRS=()
    if $IS_NVME && [ "$SMART_TYPE" = "nvme" ]; then
        while IFS= read -r line; do
            local key=$(echo "$line" | awk '{print $1}')
            local value=$(echo "$line" | awk '{print $2}')
            case "$key" in
                critical_warning) SMART_ATTRS+=("001|Критические предупреждения|$value|0|0|") ;;
                temperature) SMART_ATTRS+=("194|Температура|${value}°C|0|0|") ;;
                available_spare) SMART_ATTRS+=("232|Доступный резерв|${value}%|10|0|") ;;
                percentage_used) SMART_ATTRS+=("231|Остаток ресурса SSD|${value}%|10|0|") ;;
                data_units_read) SMART_ATTRS+=("242|Всего прочитано LBA|$value|0|0|") ;;
                data_units_written) SMART_ATTRS+=("241|Всего записано LBA|$value|0|0|") ;;
                power_cycles) SMART_ATTRS+=("012|Число включений|$value|0|0|") ;;
                power_on_hours) SMART_ATTRS+=("009|Время работы (часы)|$value|0|0|") ;;
                unsafe_shutdowns) SMART_ATTRS+=("192|Аварийные выключения|$value|0|0|") ;;
                media_errors) SMART_ATTRS+=("198|Неисправные сектора|$value|0|0|") ;;
            esac
        done <<< "$SMART_DATA"
    else
        while IFS= read -r line; do
            local id=$(echo "$line" | awk '{print $1}')
            local current=$(echo "$line" | awk '{print $4}')
            local worst=$(echo "$line" | awk '{print $5}')
            local threshold=$(echo "$line" | awk '{print $6}')
            local raw=$(echo "$line" | awk '{print $10}')
            
            local ru_name="Атрибут-$id"
            case "$id" in
                1) ru_name="Ошибки чтения" ;; 5) ru_name="Забракованные сектора" ;; 9) ru_name="Время работы (часы)" ;;
                12) ru_name="Число включений" ;; 160) ru_name="Атрибут-160" ;; 161) ru_name="Атрибут-161" ;;
                163) ru_name="Атрибут-163" ;; 164) ru_name="Атрибут-164" ;; 165) ru_name="Атрибут-165" ;;
                166) ru_name="Атрибут-166" ;; 167) ru_name="Атрибут-167" ;; 168) ru_name="Атрибут-168" ;;
                169) ru_name="Атрибут-169" ;; 175) ru_name="Дельта Wear Range" ;; 176) ru_name="Программные сбои" ;;
                177) ru_name="Сбои стирания" ;; 178) ru_name="Сообщённые неисправные блоки" ;; 181) ru_name="Программные сбои всего" ;;
                182) ru_name="Сбои стирания всего" ;; 192) ru_name="Аварийные выключения" ;; 194) ru_name="Температура" ;;
                195) ru_name="Аппаратное исправление" ;; 196) ru_name="Переназначения" ;; 197) ru_name="Нестабильные сектора" ;;
                198) ru_name="Неисправные сектора" ;; 199) ru_name="Ошибки CRC UDMA" ;; 232) ru_name="Доступный резерв" ;;
                241) ru_name="Всего записано LBA" ;; 242) ru_name="Всего прочитано LBA" ;; 245) ru_name="Атрибут-245" ;;
            esac
            
            [ -n "$id" ] && [[ "$id" =~ ^[0-9]+$ ]] && SMART_ATTRS+=("${id}|${ru_name}|${current}|${worst}|${threshold}|${raw}")
        done <<< "$SMART_DATA"
    fi
}

display_header() {
    echo "================================================================================"
    echo "  CrystalDiskInfo CLI — Информация о дисках"
    echo "================================================================================"
    echo ""
    echo "  ${CIRCLE_GOOD} Хорошо   ${CIRCLE_WARN} Тревога!   ${CIRCLE_BAD} Плохо   ${CIRCLE_UNKNOWN} Неизвестно"
    echo ""
    echo "--------------------------------------------------------------------------------"
    for i in "${!DISKS[@]}"; do
        local device="${DISKS[$i]}"
        local info="${DISK_INFO[$i]}"
        get_smart_data "$device"
        get_disk_health
        parse_temperature
        
        local status_circle=""
        case "$DISK_HEALTH" in
            GOOD) status_circle="${CIRCLE_GOOD}" ;;
            WARNING) status_circle="${CIRCLE_WARN}" ;;
            BAD) status_circle="${CIRCLE_BAD}" ;;
            *) status_circle="${CIRCLE_UNKNOWN}" ;;
        esac
        echo "  $status_circle $info $DISK_TEMP"
    done
    echo "--------------------------------------------------------------------------------"
    echo ""
}

display_disk_info() {
    local device=$1
    echo "================================================================================"
    echo "  Диск: /dev/$device"
    echo "================================================================================"
    echo ""
    echo "  Модель:          $DISK_MODEL"
    echo "  Серийный номер:  $DISK_SERIAL"
    echo "  Прошивка:        $DISK_FIRMWARE"
    echo "  Интерфейс:       $DISK_INTERFACE"
    echo "  Размер:          $DISK_SIZE"
    echo ""
    
    local health_text="Хорошо"; local health_color="$GREEN"
    [ "$DISK_HEALTH" = "WARNING" ] && { health_text="Тревога!"; health_color="$YELLOW"; }
    [ "$DISK_HEALTH" = "BAD" ] && { health_text="Плохо"; health_color="$RED"; }
    
    echo "  Состояние:       ${health_color}${BOLD}${health_text} ${DISK_HEALTH_PERCENT}%${RESET}"
    echo "  Температура:     ${BOLD}${DISK_TEMP}${RESET}"
    echo "  Время работы:    $DISK_HOURS"
    echo "  Включений:       $DISK_CYCLES"
    echo ""
}

display_smart_attributes() {
    local tmpfile=$(mktemp)
    echo "ID|Атрибут|Текущее|Худшее|Порог|Raw-значение" > "$tmpfile"
    for attr in "${SMART_ATTRS[@]}"; do echo "$attr" >> "$tmpfile"; done
    
    echo "--------------------------------------------------------------------------------"
    local line_num=0
    while IFS= read -r line; do
        if [ $line_num -eq 0 ]; then
            echo -e "${BOLD}${line}${RESET}"
        else
            if [ $((line_num % 2)) -eq 0 ]; then
                echo -e "${GREEN}${line}${RESET}"
            else
                echo "$line"
            fi
        fi
        line_num=$((line_num + 1))
    done < <(column -t -s '|' "$tmpfile")
    echo "--------------------------------------------------------------------------------"
    rm -f "$tmpfile"
}

generate_html_data_uri() {
    local device=$1
    get_smart_data "$device"
    parse_disk_info "$device"
    get_disk_health
    parse_smart_attributes
    
    local smart_rows=""
    for attr in "${SMART_ATTRS[@]}"; do
        IFS='|' read -r id name current worst threshold raw <<< "$attr"
        local desc="Специфичный атрибут производителя"
        case "$id" in
            1) desc="Ошибки при чтении данных с поверхности" ;;
            5) desc="Переназначенные сектора (bad blocks). Рост = износ" ;;
            9) desc="Общее время работы диска в часах" ;;
            12) desc="Количество полных циклов включения/выключения" ;;
            160) desc="Ошибки коррекции данных" ;;
            161) desc="Циклы программирования (записи)" ;;
            163) desc="Среднее количество циклов стирания/записи ячеек" ;;
            164) desc="Общее количество операций стирания блоков" ;;
            165) desc="Ошибки при программировании ячеек" ;;
            166) desc="Сбои при стирании блоков" ;;
            167) desc="Сбойные блоки в массиве памяти" ;;
            168) desc="Оставшиеся резервные блоки" ;;
            169) desc="Оставшийся ресурс диска в процентах" ;;
            175) desc="Разница между макс. и мин. износом ячеек" ;;
            176) desc="Сбои команд программирования" ;;
            177) desc="Сбои команд стирания" ;;
            178) desc="Блоки, отмеченные как неисправные" ;;
            181) desc="Общее количество программных сбоев" ;;
            182) desc="Общее количество сбоев стирания" ;;
            192) desc="Аварийные отключения питания (резкие выключения)" ;;
            194) desc="Текущая температура диска (°C)" ;;
            195) desc="Ошибки, исправленные аппаратной коррекцией ECC" ;;
            196) desc="Нестабильные сектора, ожидающие переназначения" ;;
            197) desc="Сектора с неисправимыми ошибками" ;;
            198) desc="Общее количество неисправных секторов" ;;
            199) desc="Ошибки CRC при передаче данных по интерфейсу" ;;
            231) desc="Оставшийся ресурс SSD (процент от гарантийного)" ;;
            232) desc="Доступные резервные блоки для замены" ;;
            233) desc="Индекс износа носителя (Media Wearout)" ;;
            241) desc="Общий объём записанных данных (LBA)" ;;
            242) desc="Общий объём прочитанных данных (LBA)" ;;
        esac
        
        local row_color="#ffffff"
        if [ "$threshold" != "0" ] && [ "$current" != "0" ] 2>/dev/null; then
            if [ "$current" -le "$threshold" ] 2>/dev/null; then row_color="#ffcccc"
            elif [ "$current" -le $((threshold + 20)) ] 2>/dev/null; then row_color="#fff3cd"; fi
        fi
        
        smart_rows+="        <tr style=\"background-color: $row_color;\"><td>$id</td><td><b>$name</b><br><small style=\"color: #666;\">$desc</small></td><td>$current</td><td>$worst</td><td>$threshold</td><td>$raw</td></tr>\n"
    done
    
    local health_text="Хорошо"; local health_color="#28a745"
    [ "$DISK_HEALTH" = "WARNING" ] && { health_text="Тревога!"; health_color="#ffc107"; }
    [ "$DISK_HEALTH" = "BAD" ] && { health_text="Плохо"; health_color="#dc3545"; }
    
    local timestamp=$(date '+%d.%m.%Y %H:%M:%S')
    
    local html_content="<!DOCTYPE html><html lang=\"ru\"><head><meta charset=\"UTF-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\"><title>SMART Отчёт: $DISK_MODEL</title>
<style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",Roboto,Arial,sans-serif;background:#f5f5f5;padding:20px;line-height:1.6}.container{max-width:1200px;margin:0 auto}h1{color:#333;margin-bottom:20px;padding-bottom:10px;border-bottom:3px solid #007bff}.info-card{background:white;border-radius:8px;padding:20px;margin-bottom:20px;box-shadow:0 2px 4px rgba(0,0,0,0.1)}.info-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:15px;margin-top:15px}.info-item{padding:10px;background:#f8f9fa;border-radius:4px;border-left:4px solid #007bff}.info-label{font-weight:bold;color:#666;font-size:0.9em}.info-value{font-size:1.1em;color:#333;margin-top:5px}.health-status{display:inline-block;padding:10px 20px;border-radius:4px;color:white;font-weight:bold;font-size:1.2em}table{width:100%;border-collapse:collapse;margin-top:15px;background:white;box-shadow:0 2px 4px rgba(0,0,0,0.1);border-radius:8px;overflow:hidden}th,td{padding:12px 15px;text-align:left;border-bottom:1px solid #dee2e6}th{background:#007bff;color:white;font-weight:bold;text-transform:uppercase;font-size:0.85em}tr:hover{background:#f8f9fa}td small{display:block;margin-top:5px;font-style:italic}.timestamp{color:#666;font-size:0.9em;margin-bottom:20px}.legend{margin-top:20px;padding:15px;background:white;border-radius:8px;box-shadow:0 2px 4px rgba(0,0,0,0.1)}.legend-item{display:inline-block;margin-right:20px;margin-bottom:10px}.legend-color{display:inline-block;width:20px;height:20px;margin-right:5px;border:1px solid #ddd;vertical-align:middle}</style></head>
<body><div class=\"container\"><h1>💾 CrystalDiskInfo CLI - Отчёт о диске</h1><p class=\"timestamp\">📅 Сгенерирован: $timestamp</p>
<div class=\"info-card\"><h2>📊 Основная информация</h2><div style=\"margin:15px 0;\"><span class=\"health-status\" style=\"background:$health_color;\">$health_text ($DISK_HEALTH_PERCENT%)</span></div>
<div class=\"info-grid\"><div class=\"info-item\"><div class=\"info-label\">Устройство</div><div class=\"info-value\">/dev/$device</div></div>
<div class=\"info-item\"><div class=\"info-label\">Модель</div><div class=\"info-value\">$DISK_MODEL</div></div>
<div class=\"info-item\"><div class=\"info-label\">Серийный номер</div><div class=\"info-value\">$DISK_SERIAL</div></div>
<div class=\"info-item\"><div class=\"info-label\">Прошивка</div><div class=\"info-value\">$DISK_FIRMWARE</div></div>
<div class=\"info-item\"><div class=\"info-label\">Интерфейс</div><div class=\"info-value\">$DISK_INTERFACE</div></div>
<div class=\"info-item\"><div class=\"info-label\">Размер</div><div class=\"info-value\">$DISK_SIZE</div></div>
<div class=\"info-item\"><div class=\"info-label\">Температура</div><div class=\"info-value\">$DISK_TEMP</div></div>
<div class=\"info-item\"><div class=\"info-label\">Время работы</div><div class=\"info-value\">$DISK_HOURS</div></div>
<div class=\"info-item\"><div class=\"info-label\">Включений</div><div class=\"info-value\">$DISK_CYCLES</div></div></div></div>
<div class=\"info-card\"><h2>🔍 SMART атрибуты</h2><table><thead><tr><th>ID</th><th>Атрибут и описание</th><th>Текущее</th><th>Худшее</th><th>Порог</th><th>Raw</th></tr></thead><tbody>
$(echo -e "$smart_rows")
</tbody></table></div>
<div class=\"legend\"><h3>📖 Легенда:</h3><div class=\"legend-item\"><span class=\"legend-color\" style=\"background:#ffffff;\"></span><span>Норма</span></div><div class=\"legend-item\"><span class=\"legend-color\" style=\"background:#fff3cd;\"></span><span>Предупреждение</span></div><div class=\"legend-item\"><span class=\"legend-color\" style=\"background:#ffcccc;\"></span><span>Критично</span></div></div>
<p style=\"margin-top:20px;color:#666;font-size:0.9em;\">💡 <b>Совет:</b> Нажмите Ctrl+S чтобы сохранить страницу</p></div></body></html>"

    local base64_html=$(echo -n "$html_content" | base64 -w 0)
    echo "data:text/html;base64,$base64_html"
}

open_data_uri_in_browser() {
    local data_uri=$1
    local uri_length=${#data_uri}
    echo " 📦 Размер отчёта: $((uri_length / 1024)) KB"
    
    [ $uri_length -gt 2000000 ] && echo -e "${YELLOW}⚠️ Предупреждение: URI очень большой, некоторые браузеры могут его заблокировать.${RESET}"
    
    local browser=""
    if command -v xdg-open &>/dev/null; then browser="xdg-open"
    elif command -v gnome-open &>/dev/null; then browser="gnome-open"
    elif command -v kde-open &>/dev/null; then browser="kde-open"
    elif command -v open &>/dev/null; then browser="open"
    elif command -v sensible-browser &>/dev/null; then browser="sensible-browser"
    else
        echo -e "${RED}❌ Не найдена команда для открытия браузера.${RESET}"
        return 1
    fi
    
    echo " 🌐 Открываю отчёт в браузере..."
    $browser "$data_uri" &>/dev/null &
    sleep 2
    
    echo -e "${GREEN}✅ Команда на открытие отправлена!${RESET}"
    echo ""
    echo "💡 Если браузер НЕ открылся (из-за ограничений безопасности на длинные ссылки):"
    echo "   1. Откройте браузер вручную"
    echo "   2. Нажмите Ctrl+V в адресной строке (ссылка уже в буфере обмена!)"
    echo "   3. Нажмите Enter"
    echo ""
    echo "💡 Чтобы сохранить: Ctrl+S в браузере"
    
    if command -v xclip &>/dev/null; then
        echo "$data_uri" | xclip -selection clipboard 2>/dev/null && echo -e "   ${GREEN}✓ Ссылка скопирована в буфер обмена!${RESET}"
    elif command -v xsel &>/dev/null; then
        echo "$data_uri" | xsel --clipboard 2>/dev/null && echo -e "   ${GREEN}✓ Ссылка скопирована в буфер обмена!${RESET}"
    fi
}

interactive_menu() {
    while true; do
        clear
        display_header
        
        echo "Выберите диск для просмотра:"
        echo ""
        for i in "${!DISKS[@]}"; do echo "  $((i + 1))) /dev/${DISKS[$i]} — ${DISK_INFO[$i]}"; done
        echo ""
        echo "  G) Сгенерировать HTML-отчёт (Data URI)"
        echo "  0) Выход"
        echo ""
        echo -n "Ваш выбор: "
        read -r choice
        
        if [ "$choice" = "0" ]; then
            echo "Выход..."
            exit 0
        elif [ "$choice" = "G" ] || [ "$choice" = "g" ]; then
            echo ""
            echo -n "Введите номер диска (1-${#DISKS[@]}): "
            read -r disk_num
            
            if [[ "$disk_num" =~ ^[0-9]+$ ]] && [ "$disk_num" -ge 1 ] && [ "$disk_num" -le "${#DISKS[@]}" ]; then
                # === ЗДЕСЬ ПРОИСХОДИТ ПРОВЕРКА И УСТАНОВКА XCLIP ===
                ensure_clipboard_tool
                
                local index=$((disk_num - 1))
                local device="${DISKS[$index]}"
                
                echo "⏳ Генерация HTML-отчёта..."
                local data_uri=$(generate_html_data_uri "$device")
                echo ""
                open_data_uri_in_browser "$data_uri"
                
                echo ""
                echo -e "${GRAY}Нажмите Enter для продолжения...${RESET}"
                read -r
            else
                echo -e "${RED}Неверный номер диска!${RESET}"
                sleep 2
            fi
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#DISKS[@]}" ]; then
            local index=$((choice - 1))
            local device="${DISKS[$index]}"
            
            clear
            display_header
            get_smart_data "$device"
            parse_disk_info "$device"
            get_disk_health
            parse_smart_attributes
            
            display_disk_info "$device"
            display_smart_attributes
            
            echo ""
            echo -e "${GRAY}Нажмите Enter для возврата в меню...${RESET}"
            read -r
        else
            echo -e "${RED}Неверный выбор!${RESET}"
            sleep 2
        fi
    done
}

single_disk_mode() {
    local device=$1
    get_smart_data "$device"
    parse_disk_info "$device"
    get_disk_health
    parse_smart_attributes
    display_header
    display_disk_info "$device"
    display_smart_attributes
}

main() {
    check_dependencies
    get_disk_list
    
    if [ ${#DISKS[@]} -eq 0 ]; then
        echo -e "${RED}Ошибка: Диски не найдены!${RESET}"
        exit 1
    fi
    
    if [ $# -gt 0 ]; then
        local device=$1
        device=$(echo "$device" | sed 's|/dev/||')
        single_disk_mode "$device"
    else
        interactive_menu
    fi
}

main "$@"
