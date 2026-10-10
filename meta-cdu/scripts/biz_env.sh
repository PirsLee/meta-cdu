#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# biz_env.sh —— 《业务API手动测试手册》§0.3 / §0.4 的可复用环境
# ===========================================================================
# 这不是一个"跑一遍就完事"的脚本，而是要 source 进交互式 shell 的环境文件：
#
#     source meta-cdu/scripts/biz_env.sh              # 默认 Session Token 认证
#     source meta-cdu/scripts/biz_env.sh --basic      # 改用 Basic 认证
#     source meta-cdu/scripts/biz_env.sh --cookie     # 改用 Cookie 认证
#
# 可先覆盖的环境变量（不改也能用，会走下面的默认值）：
#     BMC=192.168.1.100 PORT=443 BMC_USER=root BMC_PASS=0penBmc \
#         source meta-cdu/scripts/biz_env.sh
#
# ---------------------------------------------------------------------------
# 为什么必须是 source，而不能做成"环境变量"？
#   - AUTH 是 bash 数组 (-H "X-Auth-Token: ...")  —— 环境变量只能存字符串，
#     数组**根本无法 export**；故意写成数组是为了让每个元素（含带空格的
#     -H "X-Auth-Token: xxx"）保持原样传给 curl。
#   - G / S / P / C 是 shell **函数** —— 函数不是环境变量（export -f 不可移植）。
#   所以这套东西只能活在"当前 shell 的进程空间"里：**关掉终端就没了**，
#   新开一个终端要重新 source（或重新粘贴）。
# ===========================================================================

# ---------------------------------------------------------------- 必须 source
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cat >&2 <<'EOF'
[!] 请不要直接执行本文件，它需要被 source：

      source meta-cdu/scripts/biz_env.sh

    （直接执行只会在一个子进程里定义变量和函数，退出即消失）
EOF
    exit 1
fi

if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "[!] 请用 bash：bash 下执行 source meta-cdu/scripts/biz_env.sh" >&2
    return 1 2>/dev/null || exit 1
fi

for _dep in curl jq; do
    command -v "$_dep" >/dev/null 2>&1 || \
        echo "[!] 缺少依赖：$_dep（Ubuntu: apt install $_dep）" >&2
done
unset _dep

# ---------------------------------------------------------------- 配置
: "${BMC:=192.168.1.100}"
: "${PORT:=443}"
: "${BMC_USER:=root}"
: "${BMC_PASS:=0penBmc}"

BASE="https://${BMC}:${PORT}"
export BASE BMC PORT
# 注意：BMC_PASS **不导出**，避免密码进入子进程环境 / 被 `env`、`ps e` 看到。

_BMCWEB_AUTH_MODE="${1:---token}"   # source 时传参：--token | --basic | --cookie

# ---------------------------------------------------------------- 认证
login() {
    case "$_BMCWEB_AUTH_MODE" in
        --basic)
            AUTH=(-u "${BMC_USER}:${BMC_PASS}")
            echo "认证方式: Basic (-u ${BMC_USER}:***)"
            ;;
        --cookie)
            local cj=/tmp/bmcweb_cookies.txt
            curl -sk -c "$cj" -o /dev/null \
                 -X POST "${BASE}/redfish/v1/SessionService/Sessions" \
                 -H 'Content-Type: application/json' \
                 -d "{\"UserName\":\"${BMC_USER}\",\"Password\":\"${BMC_PASS}\"}" \
                 2>/dev/null
            AUTH=(-b "$cj")
            echo "认证方式: Cookie ($cj)"
            ;;
        --token|*)
            local hdr tok
            hdr=$(curl -sk --max-time 25 -D- -o /dev/null \
                  -X POST "${BASE}/redfish/v1/SessionService/Sessions" \
                  -H 'Content-Type: application/json' \
                  -d "{\"UserName\":\"${BMC_USER}\",\"Password\":\"${BMC_PASS}\"}" \
                  2>/dev/null | tr -d '\r')
            tok=$(awk -F': ' 'tolower($1)=="x-auth-token"{print $2}' <<<"$hdr")
            if [[ -n "$tok" ]]; then
                AUTH=(-H "X-Auth-Token: ${tok}")
                echo "认证方式: Session (X-Auth-Token)"
            else
                AUTH=(-u "${BMC_USER}:${BMC_PASS}")
                echo "认证方式: Basic (fallback —— Session 登录失败，请确认 BMC/USER/PASS)" >&2
            fi
            ;;
    esac
}

# ---------------------------------------------------------------- 四个主函数
# 约定：G / SP 收「路径」会自动补 $BASE；S 收「裸 curl 参数」，URL 要自己写全。

# G  路径                 GET，输出美化后的 JSON
G()  { curl -sk --max-time 25 "${AUTH[@]}" -H 'Accept: application/json' "$BASE$1"; }

# GQ 路径 jq表达式         GET，直接过 jq（省一次管道）
GQ() { curl -sk --max-time 25 "${AUTH[@]}" -H 'Accept: application/json' "$BASE$1" | jq "$2"; }

# S  裸curl参数...         原样透传，只输出状态码；响应体→/tmp/last_body，响应头→/tmp/last_hdr
S()  { curl -sk --max-time 25 "${AUTH[@]}" -o /tmp/last_body -D /tmp/last_hdr -w '%{http_code}\n' "$@"; }

# SP 路径                  只取某个路径的状态码（等价于 S "$BASE$1"）
SP() { curl -sk --max-time 25 "${AUTH[@]}" -o /tmp/last_body -D /tmp/last_hdr -w '%{http_code}\n' "$BASE$1"; }

# P  路径 JSON             PATCH  —— 只用于「修改已有资源」
P()  { curl -sk "${AUTH[@]}" -o /tmp/last_body -D /tmp/last_hdr -w '%{http_code}\n' \
         -X PATCH -H 'Content-Type: application/json' -d "$2" "$BASE$1"; echo; cat /tmp/last_body; }

# C  路径 JSON             POST   —— 用于「在集合下新建资源」、「调用 Action」
#                                  成功时额外打印 Location 头
C()  { curl -sk "${AUTH[@]}" -o /tmp/last_body -D /tmp/last_hdr -w '%{http_code}\n' \
         -X POST -H 'Content-Type: application/json' -d "$2" "$BASE$1"; echo
       grep -i '^Location' /tmp/last_hdr 2>/dev/null; cat /tmp/last_body; }

# D  路径                  DELETE
D()  { curl -sk "${AUTH[@]}" -o /tmp/last_body -D /tmp/last_hdr -w '%{http_code}\n' \
         -X DELETE "$BASE$1"; }

# 上一次响应的快捷读取
body()   { cat /tmp/last_body; }
errcode(){ jq -r '.error.code // empty' /tmp/last_body 2>/dev/null; }
location(){ grep -i '^Location' /tmp/last_hdr 2>/dev/null | awk -F': ' '{print $2}' | tr -d '\r\n'; }

# ---------------------------------------------------------------- 运行时 ID 发现
# Redfish 的资源 ID 都是从 D-Bus / EntityManager 解析出来的，不能写死。
discover() {
    echo "目标: $BASE"
    CID=$(G /redfish/v1/Chassis/ | jq -r '.Members[0]["@odata.id"] | split("/")[-1]' 2>/dev/null)

    ETH=$(G /redfish/v1/Managers/bmc/EthernetInterfaces/ \
          | jq -r '.Members[]["@odata.id"] | split("/")[-1] | select(contains("_")|not)' \
          2>/dev/null | head -1)

    SID=$(G "/redfish/v1/Chassis/$CID/Sensors/" \
          | jq -r '.Members[0]["@odata.id"] | split("/")[-1]' 2>/dev/null)

    FW=$(G /redfish/v1/UpdateService/FirmwareInventory/ \
         | jq -r '.Members[0]["@odata.id"]' 2>/dev/null)

    export CID ETH SID FW
    printf '  CID = %s\n  ETH = %s\n  SID = %s\n  FW  = %s\n' \
           "${CID:-?}" "${ETH:-?}" "${SID:-?}" "${FW:-?}"
}

# ---------------------------------------------------------------- 冒烟测试
ping_bmc() {
    local code
    code=$(SP /redfish/v1/)
    if [[ "$code" == "200" ]]; then
        echo "OK   $BASE/redfish/v1/    HTTP 200"
    else
        echo "FAIL $BASE/redfish/v1/    HTTP $code" >&2
        echo "     判读见手册 §0.5；认证问题见 §0.3" >&2
        return 1
    fi
}

# ---------------------------------------------------------------- 自动执行
echo "目标: $BASE"
login
discover
echo
echo "可用函数:  G(路径)  GQ(路径,jq)  S(裸curl)  SP(路径)  P(路径,JSON)  C(路径,JSON)  D(路径)"
echo "           discover  重新探测 ID      ping_bmc  连通性自检"
echo "           body / errcode / location  读上次响应"
echo "           login     重新登录（例如 token 过期后）"
echo
echo "提示: 写操作前先读原值，测完立刻还原 —— 见手册 §0.1 原则②"
