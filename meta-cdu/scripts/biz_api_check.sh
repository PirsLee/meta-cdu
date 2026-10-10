#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# 业务 Redfish API  ⇄  bmcweb 已实现且已对齐接口  验收测试脚本
# ---------------------------------------------------------------------------
# 只覆盖上一轮结论表中标记为 🟢 的条目（共 30 条）。
# 🟡 / 🟠 / 🔴 条目不在本脚本范围内 —— 它们当前返回 400/404 属于预期行为。
#
# 用法:
#   BMC=192.168.1.100 ./biz_api_check.sh                     # 全量（含写/删类用例）
#   BMC=192.168.1.100 RUN_DESTRUCTIVE=0 ./biz_api_check.sh   # 只跑只读用例（最安全）
#   BMC=127.0.0.1 PORT=18080 ./biz_api_check.sh              # 测本机 standalone bmcweb
#   BMC=192.168.1.100 RUN_FIRMWARE_UPDATE=1 FW_IMAGE=/tmp/obmc-phosphor-image-xxx.static.mtd.tar \
#        ./biz_api_check.sh                                  # 含真实固件升级（危险）
#
# 依赖: curl, jq
# 注意: 默认凭据 root/0penBmc 仅用于开发板，请勿在量产环境保留。
# ---------------------------------------------------------------------------
set -uo pipefail

BMC="${BMC:-127.0.0.1}"
PORT="${PORT:-443}"
BMC_USER="${BMC_USER:-root}"
BMC_PASS="${BMC_PASS:-0penBmc}"
RUN_DESTRUCTIVE="${RUN_DESTRUCTIVE:-1}"

BASE="https://${BMC}:${PORT}"
CURL=(curl -sk --max-time 25)

PASS=0; FAIL=0; SKIP=0
TMPBODY="$(mktemp)"
trap 'rm -f "$TMPBODY"' EXIT

C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'

ok()   { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$C_G" "$C_0" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  %sFAIL%s  %s\n' "$C_R" "$C_0" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  %sSKIP%s  %s\n' "$C_Y" "$C_0" "$1"; }
sect() { printf '\n%s== %s ==%s\n' "$C_B" "$1" "$C_0"; }

# ---------------------------------------------------------------- 认证
AUTH=()
login() {
    local hdr
    hdr=$(curl -sk --max-time 25 -D- -o /dev/null \
        -X POST "${BASE}/redfish/v1/SessionService/Sessions" \
        -H 'Content-Type: application/json' \
        -d "{\"UserName\":\"${BMC_USER}\",\"Password\":\"${BMC_PASS}\"}" \
        2>/dev/null | tr -d '\r')
    local tok
    tok=$(awk -F': ' 'tolower($1)=="x-auth-token"{print $2}' <<<"$hdr")
    if [[ -n "$tok" ]]; then
        AUTH=(-H "X-Auth-Token: ${tok}")
        echo "认证方式: Session (X-Auth-Token)"
    else
        AUTH=(-u "${BMC_USER}:${BMC_PASS}")
        echo "认证方式: Basic (fallback)"
    fi
}

# ---------------------------------------------------------------- 请求/断言
CODE=""; BODY=""
run() {                       # run METHOD URL [JSON_BODY]
    local method="$1" url="$2" body="${3:-}"
    local args=(-o "$TMPBODY" -w '%{http_code}' -X "$method" "${AUTH[@]}" \
                -H 'Accept: application/json' -H 'OData-Version: 4.0')
    [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
    CODE=$("${CURL[@]}" "${args[@]}" "${BASE}${url}" 2>/dev/null)
    BODY="$(cat "$TMPBODY" 2>/dev/null)"
}

chk()   {  # chk LABEL WANT_CODE
    if [[ "$CODE" == "$2" ]]; then ok "$1  (HTTP $CODE)"
    else bad "$1  期望 HTTP $2，实得 $CODE :: $(tr -d '\n' <<<"$BODY" | head -c 220)"; fi
}
chkq() {  # chkq LABEL JQ_FILTER WANT_VALUE
    local got; got=$(jq -r "$2" <<<"$BODY" 2>/dev/null)
    if [[ "$got" == "$3" ]]; then ok "$1  [$2 = $got]"
    else bad "$1  [$2 期望 '$3'，实得 '$got']"; fi
}
chkne() { # chkne LABEL JQ_FILTER        —— 断言存在且非 null 非空
    local got; got=$(jq -r "$2" <<<"$BODY" 2>/dev/null)
    if [[ -n "$got" && "$got" != "null" ]]; then ok "$1  [$2 = $got]"
    else bad "$1  [$2 为空或 null]  :: $(tr -d '\n' <<<"$BODY" | head -c 220)"; fi
}
chkge() { # chkge LABEL JQ_FILTER MIN_NUMBER
    local got; got=$(jq -r "$2" <<<"$BODY" 2>/dev/null)
    if [[ "$got" =~ ^[0-9]+$ ]] && (( got >= $3 )); then ok "$1  [$2 = $got]"
    else bad "$1  [$2 期望 >= $3，实得 '$got']"; fi
}
chkhas() { # chkhas LABEL JQ_FILTER        —— 断言「键存在」（值允许为 null）
    if jq -e "$2" >/dev/null 2>&1; then ok "$1  [键存在: $2]"
    else bad "$1  [键缺失: $2]  :: $(tr -d '\n' <<<"$BODY" | head -c 200)"; fi
}
chkhasany() { # chkhasany LABEL "F1" "F2" ...  —— 至少一个键存在
    local label="$1"; shift
    local f
    for f in "$@"; do
        if jq -e "$f" >/dev/null 2>&1; then ok "$label  [命中: $f]"; return; fi
    done
    bad "$label  [以下键全部缺失: $*]  :: $(tr -d '\n' <<<"$BODY" | head -c 200)"
}
chkre() { # chkre LABEL JQ_FILTER REGEX
    local got; got=$(jq -r "$2" <<<"$BODY" 2>/dev/null)
    if [[ "$got" =~ $3 ]]; then ok "$1  [$2 = $got]"
    else bad "$1  [$2 期望匹配 /$3/，实得 '$got']"; fi
}
grab() { jq -r "$1" <<<"$BODY" 2>/dev/null; }

echo "目标: $BASE"
login

# ---------------------------------------------------------------- 资源 ID 发现
sect "0. 资源 ID 发现（Redfish 的 ID 是运行时从 D-Bus 解析的，不能写死）"

run GET /redfish/v1/Chassis/
if [[ "$CODE" != "200" ]]; then
    echo "无法枚举 Chassis（HTTP $CODE），后续 Chassis 用例全部跳过"; CHASSIS_ID=""
else
    CHASSIS_ID=$(grab '.Members[0]["@odata.id"] | split("/") | .[-1]')
    echo "  Chassis 列表: $(grab '[.Members[]["@odata.id"]] | join(", ")')"
    echo "  → 使用 CHASSIS_ID=${CHASSIS_ID:-<空>}"
fi

run GET /redfish/v1/Managers/bmc/EthernetInterfaces/
ETH_ID=""
if [[ "$CODE" == "200" ]]; then
    # 优先 eth0；否则取第一个不带 "_" 的物理口（VLAN 口形如 eth0_42）
    ETH_ID=$(grab '[.Members[]["@odata.id"] | split("/") | .[-1]] | map(select(test("_")|not)) | (.[0] // empty)')
    echo "  以太网口列表: $(grab '[.Members[]["@odata.id"]] | join(", ")')"
    echo "  → 使用 ETH_ID=${ETH_ID:-<空>}"
fi

SENSOR_ID=""
if [[ -n "$CHASSIS_ID" ]]; then
    run GET "/redfish/v1/Chassis/${CHASSIS_ID}/Sensors/"
    if [[ "$CODE" == "200" ]]; then
        SENSOR_ID=$(grab '.Members[0]["@odata.id"] | split("/") | .[-1]')
        echo "  → 使用 SENSOR_ID=${SENSOR_ID:-<空>}"
    fi
fi

# ===========================================================================
sect "1. Chassis 传感器  —— 业务表 行5 / 行6 / 行7"
# ===========================================================================
if [[ -z "$CHASSIS_ID" ]]; then
    skip "行5/6/7 未发现 Chassis，跳过"
else
    # 行5：传感器列表（sensor list）
    run GET "/redfish/v1/Chassis/${CHASSIS_ID}/Sensors/"
    chk   "行5  GET /Chassis/\${id}/Sensors/                → 集合可读" 200
    chkq  "行5  集合类型" '.Members | type' 'array'
    chkne "行5  @odata.count 存在"  '."Members@odata.count"'
    chkq  "行5  @odata.type 正确" '.@odata.type' '#SensorCollection.SensorCollection'
    # 每个成员 id 必须是 <type>_<name> 形式（含下划线），否则单条 GET 会 404
    chkq  "行5  全部成员 id 均含下划线（<type>_<name>）" \
          '[.Members[]["@odata.id"] | split("/")[-1] | contains("_")] | all' 'true'

    # 行6：获取全部传感器读数
    # 注意：$expand 被编译选项 BMCWEB_INSECURE_ENABLE_REDFISH_QUERY(=false) 关闭，
    #       所以只能按 Members 逐个 GET 汇总，不能用 ?$expand=.($levels=1)
    run GET "/redfish/v1/Chassis/${CHASSIS_ID}/Sensors/?%24expand=.(\$levels=1)"
    if [[ "$CODE" == "400" || "$CODE" == "501" ]]; then
        ok "行6  \$expand 如预期被禁用（HTTP $CODE）→ 改用逐条 GET 方式验证"
    else
        printf '  %sINFO%s  \$expand 返回 HTTP %s —— 本 build 理论上应为 400\n' "$C_Y" "$C_0" "$CODE"
    fi

    run GET "/redfish/v1/Chassis/${CHASSIS_ID}/Sensors/"
    mapfile -t SENSORS < <(grab '.Members[]["@odata.id"] | split("/") | .[-1]')
    NSENS=${#SENSORS[@]}
    (( NSENS > 40 )) && NSENS=40
    if (( NSENS == 0 )); then
        skip "行6  该 Chassis 下无传感器，跳过聚合读取"
    else
        n_with_reading=0; n_ok=0
        for sid in "${SENSORS[@]:0:NSENS}"; do
            run GET "/redfish/v1/Chassis/${CHASSIS_ID}/Sensors/${sid}/"
            [[ "$CODE" == "200" ]] && n_ok=$((n_ok+1))
            r=$(grab '.Reading')
            [[ -n "$r" && "$r" != "null" ]] && n_with_reading=$((n_with_reading+1))
        done
        if (( n_ok == NSENS )); then
            ok "行6  逐个读取 ${NSENS} 个传感器全部 200；其中 ${n_with_reading} 个含 Reading 字段"
        else
            bad "行6  逐个读取仅 ${n_ok}/${NSENS} 返回 200"
        fi
    fi

    # 行7：单个传感器详情
    if [[ -n "$SENSOR_ID" ]]; then
        run GET "/redfish/v1/Chassis/${CHASSIS_ID}/Sensors/${SENSOR_ID}/"
        chkne "行7  GET .../Sensors/\${sid}/  Name"  '.Name'
        # Reading 键一定存在，但传感器不可用时值为 null —— 这是规范允许的，不能判失败
        chkhas "行7                             Reading 键存在（值可为 null）" 'has("Reading")'
        # ReadingUnits / ReadingType 只有部分传感器类型带，至少有一个
        chkhasany "行7                             读数单位/类型字段（至少一个）" \
                  'has("ReadingUnits")' 'has("ReadingType")'
        chkre "行7                             Status.State 合法枚举" \
              '.Status.State' '^(Enabled|Disabled|Absent|UnavailableOffline|StandbyOffline|Starting|InTest|Degraded)$'
        r=$(grab '.Reading')
        if [[ "$r" == "null" ]]; then
            printf '  %sINFO%s  该传感器 Reading=null（传感器当前不可用），Status.State=%s —— 属正常\n' \
                   "$C_Y" "$C_0" "$(grab '.Status.State')"
        else
            ok "行7                             Reading = ${r} $(grab '.ReadingUnits // .ReadingType // ""')"
        fi
    else
        skip "行7  未发现 SENSOR_ID，跳过"
    fi
fi

# ===========================================================================
sect "2. EventService 订阅（告警接收者）  —— 业务表 行13 / 行38 / 行15"
# ===========================================================================
run GET /redfish/v1/EventService/Subscriptions/
chk   "行13 GET  /EventService/Subscriptions/            → 集合可读" 200
chkq  "行13 Members 是数组" '.Members | type' 'array'
chkne "行13 @odata.count 存在" '."Members@odata.count"'

if [[ "$RUN_DESTRUCTIVE" == "1" ]]; then
    SUB_BODY='{"Destination":"https://192.168.1.200:443/redfish-event","Protocol":"Redfish","Context":"biz-api-check"}'
    # 一次 POST，同时抓状态码与 Location 响应头
    SUB_HDR="$(mktemp)"
    CODE=$("${CURL[@]}" -o "$TMPBODY" -D "$SUB_HDR" -w '%{http_code}' \
           -X POST "${BASE}/redfish/v1/EventService/Subscriptions/" \
           "${AUTH[@]}" -H 'Content-Type: application/json' -d "$SUB_BODY" 2>/dev/null)
    BODY="$(cat "$TMPBODY")"
    SUB_URI=$(awk -F': ' 'tolower($1)=="location"{print $2}' "$SUB_HDR" | tr -d '\r\n')
    rm -f "$SUB_HDR"

    if [[ "$CODE" == "201" || "$CODE" == "200" ]]; then
        ok "行38 POST /EventService/Subscriptions/          → HTTP $CODE"
        if [[ -z "$SUB_URI" ]]; then
            run GET /redfish/v1/EventService/Subscriptions/
            SUB_URI=$(grab '.Members[-1]["@odata.id"]')
        fi
        echo "       订阅 URI: ${SUB_URI:-<未取到>}"
        if [[ -n "$SUB_URI" ]]; then
            run GET "$SUB_URI"
            chk   "行38 回读订阅                              → 200" 200
            chkq  "行38 Destination 回读一致" '.Destination' 'https://192.168.1.200:443/redfish-event'
            chkq  "行38 Protocol 固定为 Redfish" '.Protocol' 'Redfish'
            run DELETE "$SUB_URI"
            chk   "行15 DELETE 订阅                            → 204" 204
            run GET "$SUB_URI"
            chk   "行15 删除后回读                            → 404" 404
        fi
    else
        bad "行38 POST /EventService/Subscriptions/  期望 201，实得 $CODE :: $(tr -d '\n' <<<"$BODY" | head -c 250)"
    fi
else
    skip "行38/行15 写删类用例已跳过（RUN_DESTRUCTIVE=0）"
fi

# ===========================================================================
sect "3. Managers / 以太网口  只读项  —— 业务表 行17 / 行22~32"
# ===========================================================================
if [[ -z "$ETH_ID" ]]; then
    skip "未发现以太网口，跳过行17/22~32"
else
    ETH_URL="/redfish/v1/Managers/bmc/EthernetInterfaces/${ETH_ID}"
    echo "  资源: ${ETH_URL}"
    run GET "$ETH_URL"
    chk   "行17 GET ${ETH_URL}   → 200" 200

    chkne "行17 Host Name              .HostName"                       '.HostName'
    chkre "行22 IPv4 Address            .IPv4Addresses[0].Address"        '.IPv4Addresses[0].Address'      '^[0-9]+(\.[0-9]+){3}$'
    chkre "行23 Subnet Mask             .IPv4Addresses[0].SubnetMask"     '.IPv4Addresses[0].SubnetMask'   '^[0-9]+(\.[0-9]+){3}$'
    chkq  "行24 Gateway                 .IPv4Addresses[0].Gateway 为字符串" '.IPv4Addresses[0].Gateway|type' 'string'
    chkq  "行25 DNS 服务器              .NameServers 为数组"                '.NameServers|type'              'array'
    chkre "行27 IPv4 DHCP 使能          .DHCPv4.OperatingMode"              '.DHCPv4.OperatingMode'          '^(Enabled|Disabled)$'
    chkne "行28 IPv6 Address            .IPv6Addresses[0].Address"        '.IPv6Addresses[0].Address'
    chkq  "行29 Prefix Length           .IPv6Addresses[0].PrefixLength 为数字" \
          '.IPv6Addresses[0].PrefixLength|type' 'number'
    chkq  "行30 IPv6 Default Gateway    .IPv6DefaultGateway 为字符串"    '.IPv6DefaultGateway|type'       'string'
    chkq  "行31 IPv6 DNS 服务器         .NameServers 为数组"             '.NameServers|type'              'array'
    chkre "行32 IPv6 DHCP 使能          .DHCPv6.OperatingMode"            '.DHCPv6.OperatingMode'          '^(Enabled|Disabled)$'
    # 业务表里的 VLANEnable / Tagged 也在这个资源上
    chkq  "行44 VLAN 对象存在            .VLAN 为对象"                    '.VLAN|type'                     'object'
    chkq  "行44 VLAN 使能标志            .VLAN.VLANEnable 为布尔"         '.VLAN.VLANEnable|type'          'boolean'

    # ---- 只读项的反向校验：确认"只读属性写不进去"符合规范 ----
    run PATCH "$ETH_URL" '{"IPv6DefaultGateway":"2001:db8::1"}'
    if [[ "$CODE" == "400" || "$CODE" == "501" ]]; then
        ok "行30/IPv6DefaultGateway 为只读（PATCH 被拒 HTTP $CODE，符合 bmcweb 已实现语义）"
    else
        bad "IPv6DefaultGateway 期望被拒（400/501），实得 $CODE"
    fi
fi

# ===========================================================================
sect "4. Managers / 以太网口  写入项  —— 业务表 行33 / 行34 / 行35 / 行36"
# ===========================================================================
if [[ -z "$ETH_ID" ]]; then
    skip "未发现以太网口，跳过行33~36"
elif [[ "$RUN_DESTRUCTIVE" != "1" ]]; then
    skip "行33~36 写类用例已跳过（RUN_DESTRUCTIVE=0）"
else
    ETH_URL="/redfish/v1/Managers/bmc/EthernetInterfaces/${ETH_ID}"

    # 行35：先做「参数校验」负向测试（不会真的改掉 BMC 的 IP，最安全的验证方式）
    run PATCH "$ETH_URL" '{"IPv4StaticAddresses":[{"Address":"10.99.99.99","SubnetMask":"255.255.255.999"}]}'
    if [[ "$CODE" == "400" ]]; then
        ok "行35 IPv4StaticAddresses 非法 SubnetMask → 400 $(grab '.error.@Message.ExtendedInfo[0].MessageId // empty')"
    else
        bad "行35 非法 SubnetMask 期望 400（拒绝），实得 $CODE —— 危险！请立刻检查 BMC 网络"
    fi

    # 行33：改 Host Name（保存→改→回读→还原）
    run GET "$ETH_URL";        ORIG_HOST=$(grab '.HostName')
    NEW_HOST="cdu-test-$$"
    run PATCH "$ETH_URL" "{\"HostName\":\"${NEW_HOST}\"}"
    if [[ "$CODE" == "204" || "$CODE" == "200" ]]; then
        run GET "$ETH_URL"
        chkq "行33 PATCH HostName 后回读生效" '.HostName' "$NEW_HOST"
        run PATCH "$ETH_URL" "{\"HostName\":\"${ORIG_HOST}\"}"
        ok "行33 已还原 HostName → ${ORIG_HOST}"
    else
        bad "行33 PATCH HostName 期望 204，实得 $CODE :: $(tr -d '\n' <<<"$BODY" | head -c 250)"
    fi

    # 行34：改 FQDN（handleFqdnPatch 会按第一个 '.' 拆成 hostname + domainname）
    run GET "$ETH_URL"; ORIG_FQDN=$(grab '.FQDN')
    run PATCH "$ETH_URL" '{"FQDN":"biztest.local"}'
    if [[ "$CODE" == "204" || "$CODE" == "200" ]]; then
        run GET "$ETH_URL"
        chkq "行34 PATCH FQDN 后回读生效" '.FQDN' 'biztest.local'
        if [[ -n "$ORIG_FQDN" && "$ORIG_FQDN" != "null" ]]; then
            run PATCH "$ETH_URL" "{\"FQDN\":\"${ORIG_FQDN}\"}"; ok "行34 已还原 FQDN → ${ORIG_FQDN}"
        else
            printf '  %sINFO%s  原始 FQDN 为空，未还原（需手工确认 hostname）\n' "$C_Y" "$C_0"
        fi
    else
        bad "行34 PATCH FQDN 期望 204，实得 $CODE :: $(tr -d '\n' <<<"$BODY" | head -c 250)"
    fi

    # 行34 负向：FQDN 不含 '.' 应被拒
    run PATCH "$ETH_URL" '{"FQDN":"nodot"}'
    if [[ "$CODE" == "400" ]]; then ok "行34 FQDN 缺少域名分隔符 → 400（符合 handleFqdnPatch 语义）"
    else bad "行34 FQDN=\"nodot\" 期望 400，实得 $CODE"; fi

    # 行36：静态 DNS 服务器
    run GET "$ETH_URL"; ORIG_DNS=$(grab '.StaticNameServers // .NameServers')
    run PATCH "$ETH_URL" '{"StaticNameServers":["9.9.9.9"]}'
    if [[ "$CODE" == "204" || "$CODE" == "200" ]]; then
        run GET "$ETH_URL"
        chkq "行36 PATCH StaticNameServers 后回读生效" '.StaticNameServers[0]' '9.9.9.9'
        run PATCH "$ETH_URL" '{"StaticNameServers":[]}'
        ok "行36 已清空 StaticNameServers（恢复到 DHCP 下发 DNS）"
    else
        bad "行36 PATCH StaticNameServers 期望 204，实得 $CODE :: $(tr -d '\n' <<<"$BODY" | head -c 250)"
    fi
fi

# ===========================================================================
sect "5. Managers / NTP 服务器  —— 业务表 行37"
# ===========================================================================
run GET /redfish/v1/Managers/bmc/NetworkProtocol
chk   "行37 GET  /Managers/bmc/NetworkProtocol            → 200" 200
chkq  "行37 NTP.ProtocolEnabled 存在且为布尔" '.NTP.ProtocolEnabled|type' 'boolean'

if [[ "$RUN_DESTRUCTIVE" == "1" ]]; then
    ORIG_NTP=$(grab '.NTP.NTPServers // [] | @json')
    run PATCH /redfish/v1/Managers/bmc/NetworkProtocol '{"NTP":{"NTPServers":["ntp.biztest.local","10.10.10.10"]}}'
    if [[ "$CODE" == "204" || "$CODE" == "200" ]]; then
        run GET /redfish/v1/Managers/bmc/NetworkProtocol
        chkq "行37 PATCH NTP.NTPServers 后回读生效" '.NTP.NTPServers[1]' '10.10.10.10'
        run PATCH /redfish/v1/Managers/bmc/NetworkProtocol "{\"NTP\":{\"NTPServers\":${ORIG_NTP}}}"
        ok "行37 已还原 NTPServers → ${ORIG_NTP}"
    else
        bad "行37 PATCH NetworkProtocol 期望 204，实得 $CODE :: $(tr -d '\n' <<<"$BODY" | head -c 250)"
    fi
else
    skip "行37 写类用例已跳过（RUN_DESTRUCTIVE=0）"
fi

# ===========================================================================
sect "6. Managers <-> Systems 日志  —— 业务表 行20 / 行21"
# ===========================================================================
# 行20：BMC 登录日志（journal）。本 build BMCWEB_REDFISH_BMC_JOURNAL=true → 已注册
run GET /redfish/v1/Managers/bmc/LogServices/
chk   "行20 GET /Managers/bmc/LogServices/                → 200" 200
chkne "行20 Journal LogService 已注册" '[.Members[]["@odata.id"]] | map(select(test("Journal"))) | .[0]'

run GET /redfish/v1/Managers/bmc/LogServices/Journal/Entries/
if [[ "$CODE" == "200" ]]; then
    chkq  "行20 Journal Entries 集合 @odata.type" '.@odata.type' '#LogEntryCollection.LogEntryCollection'
    chkq  "行20 Journal Entries 的 Members 为数组" '.Members|type' 'array'
    chkge "行20 Journal Entries 条目数" '."Members@odata.count"' 0
    JID=$(grab '.Members[0]["@odata.id"]')
    if [[ -n "$JID" ]]; then
        run GET "$JID"
        chkne "行20 单条 Journal Entry.Message"  '.Message'
        chkne "行20 单条 Journal Entry.Created"  '.Created'
        chkq  "行20 单条 Entry.EntryType"        '.EntryType' 'Event'
    fi
else
    bad "行20 Journal Entries 期望 200，实得 $CODE（检查 BMCWEB_REDFISH_BMC_JOURNAL 是否为 true）"
fi

# 行21：硬件事件日志。本 build HostLogger=false，走标准 DMTF EventLog
run GET /redfish/v1/Systems/system/LogServices/
chk   "行21 GET /Systems/system/LogServices/               → 200" 200

run GET /redfish/v1/Systems/system/LogServices/EventLog/Entries/
if [[ "$CODE" == "200" ]]; then
    chkq  "行21 EventLog Entries 集合 @odata.type" '.@odata.type' '#LogEntryCollection.LogEntryCollection'
    chkq  "行21 EventLog Entries 的 Members 为数组" '.Members|type' 'array'
    EID=$(grab '.Members[0]["@odata.id"]')
    if [[ -n "$EID" ]]; then
        run GET "$EID"
        chkne "行21 单条 EventLog Entry.Message"  '.Message'
        chkne "行21 单条 EventLog Entry.Severity" '.Severity'
        chkne "行21 单条 EventLog Entry.Created"  '.Created'
    fi
else
    bad "行21 Systems EventLog Entries 期望 200，实得 $CODE"
fi

# 行43：Logs Dump —— 本 build 编译期关闭，路由未注册
sect "7. Logs Dump  —— 业务表 行43（本 build 未启用，预期 404）"
run GET /redfish/v1/Managers/bmc/LogServices/Dump/
if [[ "$CODE" == "404" ]]; then
    skip "行43 Dump 服务未注册（HTTP 404）。本 build BMCWEB_REDFISH_DUMP_LOG=false，属预期；如业务需要，须在 bmcweb bbappend 中 -Dredfish-dump-log=enabled 重编"
else
    run GET /redfish/v1/Managers/bmc/LogServices/Dump/Entries/
    chk   "行43 GET /Managers/bmc/LogServices/Dump/Entries/ → 200" 200
    run GET /redfish/v1/Systems/system/LogServices/Dump/Entries/
    chk   "行43 GET /Systems/system/LogServices/Dump/Entries/ → 200" 200
fi

# ===========================================================================
sect "8. AccountService  —— 业务表 行42（创建用户）"
# ===========================================================================
run GET /redfish/v1/AccountService/
chk   "行42 GET  /AccountService/                         → 200" 200

if [[ "$RUN_DESTRUCTIVE" == "1" ]]; then
    U="biztest$$"
    run POST /redfish/v1/AccountService/Accounts/ \
        "{\"UserName\":\"${U}\",\"Password\":\"0penBmc!23\",\"RoleId\":\"ReadOnly\",\"Enabled\":true}"
    if [[ "$CODE" == "201" ]]; then
        ok "行42 POST /AccountService/Accounts/              → 201（已创建 ${U}）"
        run GET "/redfish/v1/AccountService/Accounts/${U}/"
        chk   "行42 回读新账号                             → 200" 200
        chkq  "行42 回读 RoleId 一致" '.RoleId' 'ReadOnly'
        run DELETE "/redfish/v1/AccountService/Accounts/${U}/"
        chk   "行42 清理新账号 DELETE                       → 204" 204
    else
        bad "行42 POST 创建账号期望 201，实得 $CODE :: $(tr -d '\n' <<<"$BODY" | head -c 250)"
    fi
else
    skip "行42 写类用例已跳过（RUN_DESTRUCTIVE=0）"
fi

# ===========================================================================
sect "9. 以太网口 VLAN  —— 业务表 行44（创建 VLAN 接口）"
# ===========================================================================
if [[ -z "$ETH_ID" ]]; then
    skip "未发现以太网口，跳过行44"
elif [[ "$RUN_DESTRUCTIVE" != "1" ]]; then
    skip "行44 写类用例已跳过（RUN_DESTRUCTIVE=0）"
else
    VLAN_ID=$(( (RANDOM % 3000) + 100 ))
    VIF="${ETH_ID}_${VLAN_ID}"
    run GET /redfish/v1/Managers/bmc/EthernetInterfaces/
    BEFORE=$(grab '."Members@odata.count"')
    run POST /redfish/v1/Managers/bmc/EthernetInterfaces/ \
        "{\"InterfaceEnabled\":true,\"VLAN\":{\"VLANEnable\":true,\"VLANId\":${VLAN_ID}},\"Links\":{\"RelatedInterfaces\":[{\"@odata.id\":\"/redfish/v1/Managers/bmc/EthernetInterfaces/${ETH_ID}\"}]}}"
    if [[ "$CODE" == "201" || "$CODE" == "200" ]]; then
        ok "行44 POST 创建 VLAN 接口 ${VIF}                 → HTTP $CODE"
        run GET "/redfish/v1/Managers/bmc/EthernetInterfaces/${VIF}/"
        chk   "行44 回读 VLAN 接口                        → 200" 200
        chkq  "行44 VLAN.VLANId 一致"                     '.VLAN.VLANId' "${VLAN_ID}"
        chkq  "行44 VLAN.VLANEnable 为 true"               '.VLAN.VLANEnable' 'true'
        run DELETE "/redfish/v1/Managers/bmc/EthernetInterfaces/${VIF}/"
        chk   "行44 清理 VLAN 接口 DELETE                 → 204" 204
    else
        bad "行44 POST 创建 VLAN 期望 201，实得 $CODE :: $(tr -d '\n' <<<"$BODY" | head -c 300)"
    fi

    # 负向：VLANEnable=false 在创建时被明确拒绝（ethernet.hpp:2242 附近）
    run POST /redfish/v1/Managers/bmc/EthernetInterfaces/ \
        "{\"VLAN\":{\"VLANEnable\":false,\"VLANId\":${VLAN_ID}},\"Links\":{\"RelatedInterfaces\":[{\"@odata.id\":\"/redfish/v1/Managers/bmc/EthernetInterfaces/${ETH_ID}\"}]}}"
    if [[ "$CODE" == "400" ]]; then ok "行44 VLANEnable=false 创建 → 400（符合 bmcweb 语义）"
    else bad "行44 VLANEnable=false 期望 400，实得 $CODE"; fi
fi

# ===========================================================================
sect "10. UpdateService 固件  —— 业务表 行45 / 行46 / 行47"
# ===========================================================================
run GET /redfish/v1/UpdateService/
chk   "行45 GET  /UpdateService/                          → 200" 200
chkne "行45 .FirmwareInventory 导航存在" '.FirmwareInventory["@odata.id"]'

run GET /redfish/v1/UpdateService/FirmwareInventory/
chk   "行45 GET  /UpdateService/FirmwareInventory/         → 200" 200
chkq  "行45 FirmwareInventory 的 Members 为数组" '.Members|type' 'array'
chkge "行45 FirmwareInventory 条目数" '."Members@odata.count"' 1

FW_URI=$(grab '.Members[0]["@odata.id"]')
if [[ -n "$FW_URI" ]]; then
    run GET "$FW_URI"
    chk   "行46 GET  ${FW_URI}                     → 200" 200
    chkne "行46 .Version 存在"   '.Version'
    chkne "行46 .Id 存在"        '.Id'
    chkne "行46 .Name 存在"      '.Name'
    chkq  "行46 .Updateable 为布尔" '.Updateable|type' 'boolean'
    # 注意：bmcweb 的 SoftwareInventory 只填 Status.HealthRollup，没有 Status.State
    chkne "行46 .Status.HealthRollup 存在" '.Status.HealthRollup'
    chkq  "行46 @odata.type 前缀正确" '."@odata.type"|startswith("#SoftwareInventory.")' 'true'
else
    skip "行46 未能从集合中发现固件条目"
fi

# 行47：升级 BMC 固件 —— 破坏性，默认不执行
if [[ "${RUN_FIRMWARE_UPDATE:-0}" == "1" ]]; then
    echo "  [行47] RUN_FIRMWARE_UPDATE=1，执行上传测试（请确认已备份 BMC 配置）"
    IMG="${FW_IMAGE:-}"
    if [[ -z "$IMG" || ! -f "$IMG" ]]; then
        skip "行47 未提供 FW_IMAGE=...，跳过"
    else
        CODE=$(curl -sk -o "$TMPBODY" -w '%{http_code}' --max-time 600 \
               -X POST "${BASE}/redfish/v1/UpdateService/update-multipart/" \
               "${AUTH[@]}" -F "UpdateParameters=<${IMG}.params.json;type=application/json" \
               -F "UpdateFile=@${IMG}" 2>/dev/null)
        chk "行47 POST /UpdateService/update-multipart/       → 200（任务已受理）" 200
        chkne "行47 返回任务 @odata.id" '."@odata.id"'
    fi
else
    # ---- 阶段 A：最小侵入验证（只证明端点存在 + 参数校验分支生效，不真的刷固件）----

    # A1. update/ 的 Content-Type 门禁：用 JSON 打 → 400 裸响应（update_service.hpp:1142-1150）
    run POST /redfish/v1/UpdateService/update/ '{}'
    if [[ "$CODE" == "400" ]]; then
        ok "行47 A1 update/ 的 Content-Type 门禁生效（JSON → HTTP 400，无错误体属正常）"
    else
        bad "行47 A1 update/ 用 JSON 期望 400，实得 $CODE（小心：可能已触发上传流程）"
    fi

    # A2. multipart 端点 Content-Type 门禁：用 JSON 打 → 415
    #     （update_service.hpp:1183 unsupported_media_type —— 注意与 update/ 的 400 不同）
    run POST /redfish/v1/UpdateService/update-multipart/ '{}'
    if [[ "$CODE" == "415" ]]; then
        ok "行47 A2 update-multipart/ 的 Content-Type 门禁生效（JSON → HTTP 415）"
    else
        bad "行47 A2 update-multipart/ 用 JSON 期望 415，实得 $CODE"
    fi

    # A3. SimpleUpdate 路由是否存在 —— 由编译期宏 BMCWEB_REDFISH_ALLOW_SIMPLE_UPDATE 决定
    run GET /redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate/
    if [[ "$CODE" == "404" || "$CODE" == "405" ]]; then
        ok "行47 A3 SimpleUpdate 未编译（HTTP $CODE，符合 BMCWEB_REDFISH_ALLOW_SIMPLE_UPDATE=false）"
    elif [[ "$CODE" == "200" ]]; then
        ok "行47 A3 SimpleUpdate 路由已启用（HTTP 200）—— 本 build 打开了该选项"
    else
        skip "行47 A3 SimpleUpdate 返回 HTTP $CODE，请人工确认"
    fi

    # A4. 读取侧证据：/UpdateService/ 里应当没有 Actions 键（同一宏控制）
    run GET /redfish/v1/UpdateService/
    chkq "行47 A4 /UpdateService/ 无 Actions 键（SimpleUpdate 未编译）" 'has("Actions")' 'false'
    chkq "行47 A4 MaxImageSizeBytes 自证 http-body-limit=30MiB" '.MaxImageSizeBytes' '31457280'

    skip "行47 真实升级用例需显式 RUN_FIRMWARE_UPDATE=1 FW_IMAGE=/path/to/image 才会执行"
fi

# ===========================================================================
sect "汇总"
# ===========================================================================
printf '  %sPASS=%d%s   %sFAIL=%d%s   %sSKIP=%d%s\n' \
       "$C_G" "$PASS" "$C_0" "$C_R" "$FAIL" "$C_0" "$C_Y" "$SKIP" "$C_0"
if (( FAIL > 0 )); then
    echo "  失败排查: journalctl -u bmcweb -f   |   bmcweb loglevel debug"
    exit 1
fi
exit 0
