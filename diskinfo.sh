#!/bin/bash
# ============================================================================
# CrystalDiskInfo CLI — Исправленная версия с правильным выравниванием
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
    
    if ! command -v smartctl &>/dev/null; then
        missing+=("smartctl (smartmontools)")
    fi
    
    if ! command -v lsblk &>/dev/null; then
        missing+=("lsblk (util-linux)")
    fi
    
    if ! command -v column &>/dev/null; then
        missing+=("column (util-linux)")
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Ошибка: Не установлены необходимые пакеты:${RESET}"
        for pkg in "${missing[@]}"; do
            echo "  - $pkg"
        done
        echo ""
        echo "Установка:"
        echo "  Debian/Ubuntu:  sudo apt install smartmontools util-linux"
        echo "  Fedora/RHEL:    sudo dnf install smartmontools util-linux"
        echo "  Arch:           sudo pacman -S smartmontools util-linux"
        exit 1
    fi
}

get_disk_list() {
    DISKS=()
    DISK_INFO=()
    
    while IFS= read -r line; do
        local dev=$(echo "$line" | awk '{print $1}')
        local model=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ *//')
        
        if [[ "$dev" =~ ^(loop|ram|dm) ]]; then
            continue
        fi
        
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
        if [ -n "$temp_raw" ]; then
            DISK_TEMP="$((temp_raw & 0xFF))°C"
        fi
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
        if [ -n "$hours" ]; then
            DISK_HOURS="${hours} ч"
        fi
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
        if [ -n "$cycles" ]; then
            DISK_CYCLES="${cycles} раз"
        fi
    fi
}

get_disk_health() {
    local health="GOOD"
    local health_percent=100
    
    if $IS_NVME; then
        if [ "$SMART_TYPE" = "nvme" ]; then
            local pct_used=$(echo "$SMART_DATA" | grep -i "percentage_used" | awk '{print $2}')
            if [ -n "$pct_used" ]; then
                health_percent=$((100 - pct_used))
            fi
        fi
    else
        local life_left=$(echo "$SMART_DATA" | grep -E "^(231|233) " | awk '{print $4}')
        if [ -n "$life_left" ]; then
            health_percent=$life_left
        fi
        
        local reallocated=$(echo "$SMART_DATA" | grep -E "^  5 " | awk '{print $10}')
        if [ -n "$reallocated" ] && [ "$reallocated" -gt 0 ] 2>/dev/null; then
            health="WARNING"
        fi
        
        local unstable=$(echo "$SMART_DATA" | grep -E "^197 " | awk '{print $10}')
        if [ -n "$unstable" ] && [ "$unstable" -gt 0 ] 2>/dev/null; then
            health="WARNING"
        fi
    fi
    
    if [ "$health_percent" -lt 10 ]; then
        health="BAD"
    elif [ "$health_percent" -lt 50 ]; then
        health="WARNING"
    fi
    
    DISK_HEALTH=$health
    DISK_HEALTH_PERCENT=$health_percent
}

parse_smart_attributes() {
    SMART_ATTRS=()
    
    if $IS_NVME; then
        if [ "$SMART_TYPE" = "nvme" ]; then
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
        fi
    else
        while IFS= read -r line; do
            local id=$(echo "$line" | awk '{print $1}')
            local current=$(echo "$line" | awk '{print $4}')
            local worst=$(echo "$line" | awk '{print $5}')
            local threshold=$(echo "$line" | awk '{print $6}')
            local raw=$(echo "$line" | awk '{print $10}')
            
            local ru_name=""
            case "$id" in
                1) ru_name="Ошибки чтения" ;;
                5) ru_name="Забракованные сектора" ;;
                9) ru_name="Время работы (часы)" ;;
                12) ru_name="Число включений" ;;
                160) ru_name="Атрибут-160" ;;
                161) ru_name="Атрибут-161" ;;
                163) ru_name="Атрибут-163" ;;
                164) ru_name="Атрибут-164" ;;
                165) ru_name="Атрибут-165" ;;
                166) ru_name="Атрибут-166" ;;
                167) ru_name="Атрибут-167" ;;
                168) ru_name="Атрибут-168" ;;
                169) ru_name="Атрибут-169" ;;
                175) ru_name="Дельта Wear Range" ;;
                176) ru_name="Программные сбои" ;;
                177) ru_name="Сбои стирания" ;;
                178) ru_name="Сообщённые неисправные блоки" ;;
                181) ru_name="Программные сбои всего" ;;
                182) ru_name="Сбои стирания всего" ;;
                192) ru_name="Аварийные выключения" ;;
                194) ru_name="Температура" ;;
                195) ru_name="Аппаратное исправление" ;;
                196) ru_name="Переназначения" ;;
                197) ru_name="Нестабильные сектора" ;;
                198) ru_name="Неисправные сектора" ;;
                199) ru_name="Ошибки CRC UDMA" ;;
                232) ru_name="Доступный резерв" ;;
                241) ru_name="Всего записано LBA" ;;
                242) ru_name="Всего прочитано LBA" ;;
                245) ru_name="Атрибут-245" ;;
                *) ru_name="Атрибут-$id" ;;
            esac
            
            if [ -n "$id" ] && [[ "$id" =~ ^[0-9]+$ ]]; then
                SMART_ATTRS+=("${id}|${ru_name}|${current}|${worst}|${threshold}|${raw}")
            fi
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
    
    local health_text=""
    local health_color=""
    case "$DISK_HEALTH" in
        GOOD) 
            health_text="Хорошо"
            health_color="$GREEN"
            ;;
        WARNING)
            health_text="Тревога!"
            health_color="$YELLOW"
            ;;
        BAD)
            health_text="Плохо"
            health_color="$RED"
            ;;
    esac
    
    echo "  Состояние:       ${health_color}${BOLD}${health_text} ${DISK_HEALTH_PERCENT}%${RESET}"
    echo "  Температура:     ${BOLD}${DISK_TEMP}${RESET}"
    echo "  Время работы:    $DISK_HOURS"
    echo "  Включений:       $DISK_CYCLES"
    echo ""
}

display_smart_attributes() {
    local tmpfile=$(mktemp)
    
    echo "ID|Атрибут|Текущее|Худшее|Порог|Raw-значение" > "$tmpfile"
    
    for attr in "${SMART_ATTRS[@]}"; do
        echo "$attr" >> "$tmpfile"
    done
    
    echo "--------------------------------------------------------------------------------"
    
    # Сначала выравниваем через column, потом построчно раскрашиваем
    local line_num=0
    while IFS= read -r line; do
        if [ $line_num -eq 0 ]; then
            # Заголовок — жирный белый
            echo -e "${BOLD}${line}${RESET}"
        else
            if [ $((line_num % 2)) -eq 0 ]; then
                # Чётные строки — серый (приглушённый)
                echo -e "${GREEN}${line}${RESET}"
            else
                # Нечётные строки — обычный белый
                echo "$line"
            fi
        fi
        line_num=$((line_num + 1))
    done < <(column -t -s '|' "$tmpfile")
    
    echo "--------------------------------------------------------------------------------"
    
    rm -f "$tmpfile"
}

interactive_menu() {
    while true; do
        clear
        display_header
        
        echo "Выберите диск для просмотра:"
        echo ""
        
        for i in "${!DISKS[@]}"; do
            echo "  $((i + 1))) /dev/${DISKS[$i]} — ${DISK_INFO[$i]}"
        done
        
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
                local index=$((disk_num - 1))
                local device="${DISKS[$index]}"
                
                echo "⏳ Генерация HTML-отчёта..."
                local data_uri=$(generate_html_data_uri "$device")
                
                echo ""
                open_data_uri_in_browser "$data_uri"
                
                echo ""
                echo "${GRAY}Нажмите Enter для продолжения...${RESET}"
                read -r
            else
                echo "${RED}Неверный номер диска!${RESET}"
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
            echo "${GRAY}Нажмите Enter для возврата в меню...${RESET}"
            read -r
        else
            echo "${RED}Неверный выбор!${RESET}"
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

generate_html_data_uri() {
    local device=$1
    get_smart_data "$device"
    parse_disk_info "$device"
    get_disk_health
    parse_smart_attributes
    
    # Генерируем HTML
    local html_content=""
    
    # SMART атрибуты с описаниями
    local smart_rows=""
    for attr in "${SMART_ATTRS[@]}"; do
        IFS='|' read -r id name current worst threshold raw <<< "$attr"
        
        local desc=""
        case "$id" in
            1) desc="Количество ошибок при чтении данных с поверхности диска" ;;
            5) desc="Количество переназначенных секторов (bad blocks). Рост указывает на износ диска" ;;
            9) desc="Общее время работы диска в часах" ;;
            12) desc="Количество полных циклов включения/выключения диска" ;;
            160) desc="Количество ошибок коррекции данных" ;;
            161) desc="Количество циклов программирования (записи)" ;;
            163) desc="Среднее количество циклов стирания/записи ячеек памяти" ;;
            164) desc="Общее количество операций стирания блоков памяти" ;;
            165) desc="Количество ошибок при программировании ячеек" ;;
            166) desc="Количество сбоев при стирании блоков" ;;
            167) desc="Количество сбойных блоков в массиве памяти" ;;
            168) desc="Количество оставшихся резервных блоков" ;;
            169) desc="Оставшийся ресурс диска в процентах (100% = новый)" ;;
            175) desc="Разница между максимальным и минимальным износом ячеек" ;;
            176) desc="Количество сбоев команд программирования" ;;
            177) desc="Количество сбоев команд стирания" ;;
            178) desc="Количество блоков, отмеченных как неисправные" ;;
            181) desc="Общее количество программных сбоев" ;;
            182) desc="Общее количество сбоев стирания" ;;
            192) desc="Количество аварийных отключений питания (резких выключений)" ;;
            194) desc="Текущая температура диска в градусах Цельсия" ;;
            195) desc="Количество ошибок, исправленных аппаратной коррекцией ECC" ;;
            196) desc="Количество нестабильных секторов, ожидающих переназначения" ;;
            197) desc="Количество секторов с неисправимыми ошибками" ;;
            198) desc="Общее количество неисправных секторов" ;;
            199) desc="Количество ошибок CRC при передаче данных по интерфейсу" ;;
            231) desc="Оставшийся ресурс SSD (процент от гарантийного)" ;;
            232) desc="Количество доступных резервных блоков для замены" ;;
            233) desc="Индекс износа носителя (Media Wearout Indicator)" ;;
            241) desc="Общий объём записанных данных (в LBA)" ;;
            242) desc="Общий объём прочитанных данных (в LBA)" ;;
            245) desc="Специфичный атрибут производителя" ;;
            *) desc="Специфичный атрибут производителя" ;;
        esac
        
        local row_color="#ffffff"
        if [ "$threshold" != "0" ] && [ "$current" != "0" ] 2>/dev/null; then
            if [ "$current" -le "$threshold" ] 2>/dev/null; then
                row_color="#ffcccc"
            elif [ "$current" -le $((threshold + 20)) ] 2>/dev/null; then
                row_color="#fff3cd"
            fi
        fi
        
        smart_rows+="        <tr style=\"background-color: $row_color;\">
            <td>$id</td>
            <td><b>$name</b><br><small style=\"color: #666;\">$desc</small></td>
            <td>$current</td>
            <td>$worst</td>
            <td>$threshold</td>
            <td>$raw</td>
        </tr>
"
    done
    
    local health_text="Хорошо"
    local health_color="#28a745"
    case "$DISK_HEALTH" in
        WARNING) 
            health_text="Тревога!"
            health_color="#ffc107"
            ;;
        BAD)
            health_text="Плохо"
            health_color="#dc3545"
            ;;
    esac
    
    local timestamp=$(date '+%d.%m.%Y %H:%M:%S')
    
    # Создаём HTML
    html_content="<!DOCTYPE html>
<html lang=\"ru\">
<head>
    <meta charset=\"UTF-8\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
    <title>CrystalDiskInfo CLI - Отчёт: $DISK_MODEL</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { 
            font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, \"Helvetica Neue\", Arial, sans-serif;
            background: #f5f5f5;
            padding: 20px;
            line-height: 1.6;
        }
        .container { max-width: 1200px; margin: 0 auto; }
        h1 { 
            color: #333; 
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 3px solid #007bff;
        }
        .info-card {
            background: white;
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .info-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 15px;
            margin-top: 15px;
        }
        .info-item {
            padding: 10px;
            background: #f8f9fa;
            border-radius: 4px;
            border-left: 4px solid #007bff;
        }
        .info-label { font-weight: bold; color: #666; font-size: 0.9em; }
        .info-value { font-size: 1.1em; color: #333; margin-top: 5px; }
        .health-status {
            display: inline-block;
            padding: 10px 20px;
            border-radius: 4px;
            color: white;
            font-weight: bold;
            font-size: 1.2em;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 15px;
            background: white;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            border-radius: 8px;
            overflow: hidden;
        }
        th, td {
            padding: 12px 15px;
            text-align: left;
            border-bottom: 1px solid #dee2e6;
        }
        th {
            background: #007bff;
            color: white;
            font-weight: bold;
            text-transform: uppercase;
            font-size: 0.85em;
        }
        tr:hover { background: #f8f9fa; }
        td small { display: block; margin-top: 5px; font-style: italic; }
        .timestamp {
            color: #666;
            font-size: 0.9em;
            margin-bottom: 20px;
        }
        .legend {
            margin-top: 20px;
            padding: 15px;
            background: white;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .legend-item {
            display: inline-block;
            margin-right: 20px;
            margin-bottom: 10px;
        }
        .legend-color {
            display: inline-block;
            width: 20px;
            height: 20px;
            margin-right: 5px;
            border: 1px solid #ddd;
            vertical-align: middle;
        }
    </style>
</head>
<body>
    <div class=\"container\">
        <h1>💾 CrystalDiskInfo CLI - Отчёт о диске</h1>
        <p class=\"timestamp\">📅 Сгенерирован: $timestamp</p>
        
        <div class=\"info-card\">
            <h2>📊 Основная информация</h2>
            <div style=\"margin: 15px 0;\">
                <span class=\"health-status\" style=\"background: $health_color;\">
                    $health_text ($DISK_HEALTH_PERCENT%)
                </span>
            </div>
            <div class=\"info-grid\">
                <div class=\"info-item\">
                    <div class=\"info-label\">Устройство</div>
                    <div class=\"info-value\">/dev/$device</div>
                </div>
                <div class=\"info-item\">
                    <div class=\"info-label\">Модель</div>
                    <div class=\"info-value\">$DISK_MODEL</div>
                </div>
                <div class=\"info-item\">
                    <div class=\"info-label\">Серийный номер</div>
                    <div class=\"info-value\">$DISK_SERIAL</div>
                </div>
                <div class=\"info-item\">
                    <div class=\"info-label\">Прошивка</div>
                    <div class=\"info-value\">$DISK_FIRMWARE</div>
                </div>
                <div class=\"info-item\">
                    <div class=\"info-label\">Интерфейс</div>
                    <div class=\"info-value\">$DISK_INTERFACE</div>
                </div>
                <div class=\"info-item\">
                    <div class=\"info-label\">Размер</div>
                    <div class=\"info-value\">$DISK_SIZE</div>
                </div>
                <div class=\"info-item\">
                    <div class=\"info-label\">Температура</div>
                    <div class=\"info-value\">$DISK_TEMP</div>
                </div>
                <div class=\"info-item\">
                    <div class=\"info-label\">Время работы</div>
                    <div class=\"info-value\">$DISK_HOURS</div>
                </div>
                <div class=\"info-item\">
                    <div class=\"info-label\">Включений</div>
                    <div class=\"info-value\">$DISK_CYCLES</div>
                </div>
            </div>
        </div>
        
        <div class=\"info-card\">
            <h2>🔍 SMART атрибуты</h2>
            <table>
                <thead>
                    <tr>
                        <th>ID</th>
                        <th>Атрибут и описание</th>
                        <th>Текущее</th>
                        <th>Худшее</th>
                        <th>Порог</th>
                        <th>Raw</th>
                    </tr>
                </thead>
                <tbody>
$smart_rows
                </tbody>
            </table>
        </div>
        
        <div class=\"legend\">
            <h3>📖 Легенда:</h3>
            <div class=\"legend-item\">
                <span class=\"legend-color\" style=\"background: #ffffff;\"></span>
                <span>Норма</span>
            </div>
            <div class=\"legend-item\">
                <span class=\"legend-color\" style=\"background: #fff3cd;\"></span>
                <span>Предупреждение (близко к порогу)</span>
            </div>
            <div class=\"legend-item\">
                <span class=\"legend-color\" style=\"background: #ffcccc;\"></span>
                <span>Критично (ниже порога)</span>
            </div>
        </div>
        
        <p style=\"margin-top: 20px; color: #666; font-size: 0.9em;\">
            💡 <b>Совет:</b> Нажмите Ctrl+S чтобы сохранить страницу
        </p>
    </div>
</body>
</html>"

    # Кодируем HTML в base64
    local base64_html=$(echo -n "$html_content" | base64 -w 0)
    
    # Создаём Data URI
    local data_uri="data:text/html;base64,$base64_html"
    
    echo "$data_uri"
}

open_data_uri_in_browser() {
    local data_uri=$1
    
    # Проверяем длину URI
    local uri_length=${#data_uri}
    echo " Размер отчёта: $((uri_length / 1024)) KB"
    
    if [ $uri_length -gt 2000000 ]; then
        echo "️  Предупреждение: URI очень большой, некоторые браузеры могут не открыть"
    fi
    
    # Определяем браузер
    local browser=""
    if command -v xdg-open &>/dev/null; then
        browser="xdg-open"
    elif command -v gnome-open &>/dev/null; then
        browser="gnome-open"
    elif command -v kde-open &>/dev/null; then
        browser="kde-open"
    elif command -v open &>/dev/null; then
        browser="open"
    elif command -v sensible-browser &>/dev/null; then
        browser="sensible-browser"
    else
        echo "❌ Не найдена команда для открытия браузера"
        return 1
    fi
    
    echo " Открываю отчёт в браузере..."
    
    # Открываем data URI
    $browser "$data_uri" &>/dev/null &
    
    sleep 2
    echo "✅ Отчёт открыт в браузере!"
    echo ""
    echo "💡 Чтобы сохранить:"
    echo "   1. В браузере нажмите Ctrl+S (Cmd+S на Mac)"
    echo "   2. Выберите 'Веб-страница полностью' или 'HTML только'"
    echo ""
    echo "📋 Data URI ссылка скопирована в буфер (если установлен xclip)"
    
    # Пытаемся скопировать в буфер обмена
    if command -v xclip &>/dev/null; then
        echo "$data_uri" | xclip -selection clipboard 2>/dev/null && echo "   ✓ Ссылка в буфере обмена"
    elif command -v xsel &>/dev/null; then
        echo "$data_uri" | xsel --clipboard 2>/dev/null && echo "   ✓ Ссылка в буфере обмена"
    fi
}

main() {
    check_dependencies
    get_disk_list
    
    if [ ${#DISKS[@]} -eq 0 ]; then
        echo "${RED}Ошибка: Диски не найдены!${RESET}"
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
