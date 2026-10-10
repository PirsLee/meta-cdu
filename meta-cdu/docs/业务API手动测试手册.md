# 业务 Redfish API 手动测试手册

> 范围：**仅覆盖 bmcweb 已实现且与业务 API 已对齐的 30 条 🟢 条目**。
> 🟡 / 🟠 / 🔴 条目不在本手册内 —— 它们当前返回 400/404 属于预期行为。
>
> 目标机器：`evb-ast2600`，本 build 的实际配置见 §0.2。

---

## 0. 测试前准备

### 0.1 三个通用原则（先读这一段，后面所有用例都遵循）

| 原则 | 说明 |
|---|---|
| **① ID 不许写死** | Redfish 的资源 ID（Chassis id、网口名、传感器名、固件条目名）都是运行时从 D-Bus / EntityManager 解析出来的。业务表里写的 `Chassis/cdu` 只是**示意**，实际测试必须先调集合接口查真实 ID。 |
| **② 写操作必须"读 → 改 → 读回 → 还原"** | 手动测一件事改动，必须先在内存里存下原值，改完回读确认生效，最后**立刻还原**。否则测完 BMC 网络/主机名就是坏的。 |
| **③ 危险项只做"负向校验"** | 改静态 IP、刷固件这类操作一旦成功就可能断网或变砖。手动测试只用「非法参数 → 期望 400」来证明**入参校验分支跑到了**，不追求真正写入成功。 |

### 0.2 本 build 的实际编译配置（决定哪些测法可行）

来源：`build/evb-ast2600/tmp/work/.../bmcweb/1.0+git/build/config/bmcweb_config.h`

| 宏 | 值 | 对本手册的影响 |
|---|---|---|
| `BMCWEB_REDFISH_MANAGER_URI_NAME` | `"bmc"` | 管理器固定 `/redfish/v1/Managers/bmc` |
| `BMCWEB_REDFISH_SYSTEM_URI_NAME` | `"system"` | 系统固定 `/redfish/v1/Systems/system` |
| `BMCWEB_BASIC_AUTH` / `SESSION_AUTH` / `COOKIE_AUTH` / `XTOKEN_AUTH` | 全 `true` | 三种认证方式都可用 |
| `BMCWEB_REDFISH_BMC_JOURNAL` | `true` | 行20 Journal 可用 |
| `BMCWEB_REDFISH_ALLOW_SIMPLE_UPDATE` | **`false`** | **`.../Actions/UpdateService.SimpleUpdate/` 未注册 → 404**，且 `/UpdateService/` 里**没有 `Actions` 键** |
| `BMCWEB_REDFISH_UPDATESERVICE_USE_DBUS` | `true` | 固件清单来自 D-Bus `xyz.openbmc_project.Software.Version` |
| `BMCWEB_REDFISH_DUMP_LOG` | **`false`** | **行43 Dump 路由未注册 → 404 是预期** |
| `BMCWEB_INSECURE_ENABLE_REDFISH_QUERY` | **`false`** | **`?$expand=` / `?$filter=` 不可用 → 返回 `501`；行6 必须改用客户端聚合**（`query_param.hpp:403/451`） |
| `BMCWEB_HTTP_BODY_LIMIT` | `30`（单位 **MiB**） | 写请求体积无虞；可在行45 用 `MaxImageSizeBytes == 31457280` 反查验证 |

### 0.3 认证与环境（三种任选，推荐第 1 种）

> **先澄清一个常见疑问**：下面这些片段**既不是"一个可执行脚本"，也不是"环境变量"**，
> 而是**要粘贴进当前交互式 shell 的普通变量 + 函数**。原因是它们**在技术上无法成为环境变量**：
>
> | 名称 | 类型 | 能否 `export` 成环境变量 |
> |---|---|---|
> | `BMC` / `BASE` / `CID` / `ETH` | 普通字符串变量 | 可以（但没必要） |
> | `AUTH` | **bash 数组** `(-H "X-Auth-Token: …")` | ❌ **不能** —— 环境变量只能存字符串 |
> | `G` / `S` / `P` / `C` | **shell 函数** | ❌ 不能（`export -f` 不可移植，且子 shell 拿不到 `AUTH`） |
>
> 所以只有两种用法：**① `source` 一个现成文件（推荐）**，或 **② 手工粘贴**。
> 无论哪种，**关掉终端就全部丢失**，新开终端必须重来一次。

**① 推荐：source 现成的环境文件**

```bash
source meta-cdu/scripts/biz_env.sh              # 默认 Session Token 认证
source meta-cdu/scripts/biz_env.sh --basic      # 改用 Basic
source meta-cdu/scripts/biz_env.sh --cookie     # 改用 Cookie
```

它会自动登录、打印 `CID` / `ETH` / `SID` / `FW` 四个运行时 ID，并定义好 `G` / `S` / `P` / `C` / `D`。
同一终端里重复 source 是安全的。若 BMC 地址不是默认值：

```bash
BMC=192.168.1.50 PORT=443 source meta-cdu/scripts/biz_env.sh
```

**② 手工粘贴（不想用文件时）**

```bash
BMC=192.168.1.100
BASE="https://$BMC"

# 方式 1：Session Token（推荐 —— 有明确有效期，泄漏风险低）
TOKEN=$(curl -sk -D- -o /dev/null -X POST "$BASE/redfish/v1/SessionService/Sessions" \
  -H 'Content-Type: application/json' \
  -d '{"UserName":"root","Password":"0penBmc"}' \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="x-auth-token"{print $2}')
AUTH=(-H "X-Auth-Token: $TOKEN")

# 方式 2：Basic（最省事，本 build 已启用）
AUTH=(-u root:0penBmc)

# 方式 3：Cookie
curl -sk -c /tmp/cj -X POST "$BASE/redfish/v1/SessionService/Sessions" ...
AUTH=(-b /tmp/cj)
```

**后续所有例子都基于下面这几个函数**（`biz_env.sh` 里是同一份定义）：

```bash
# G  路径          GET，输出美化 JSON（自动补 $BASE）
G() { curl -sk "${AUTH[@]}" -H 'Accept: application/json' "$BASE$1"; }

# S  裸curl参数... 原样透传，只输出状态码；响应体→/tmp/last_body，响应头→/tmp/last_hdr
#                  （注意：URL 要自己写全，如 S -X DELETE "$BASE/redfish/v1/..."）
S() { curl -sk "${AUTH[@]}" -o /tmp/last_body -D /tmp/last_hdr -w '%{http_code}\n' "$@"; }

# P  路径 JSON     PATCH —— 修改「已有」资源
P() { curl -sk "${AUTH[@]}" -o /tmp/last_body -D /tmp/last_hdr -w '%{http_code}\n' \
       -X PATCH -H 'Content-Type: application/json' -d "$2" "$BASE$1"; echo; cat /tmp/last_body; }

# C  路径 JSON     POST —— 在集合下「新建」资源 / 调用 Action；额外打印 Location 头
C() { curl -sk "${AUTH[@]}" -o /tmp/last_body -D /tmp/last_hdr -w '%{http_code}\n' \
       -X POST -H 'Content-Type: application/json' -d "$2" "$BASE$1"; echo
     grep -i '^Location' /tmp/last_hdr; cat /tmp/last_body; }

# D  路径          DELETE
D() { curl -sk "${AUTH[@]}" -o /tmp/last_body -D /tmp/last_hdr -w '%{http_code}\n' \
       -X DELETE "$BASE$1"; }

# SP 路径          只取某个路径的状态码（比 S -X GET 少写一截）
SP() { curl -sk "${AUTH[@]}" -o /tmp/last_body -D /tmp/last_hdr -w '%{http_code}\n' "$BASE$1"; }
```

> ⚠️ **`P` 只发 PATCH，`C` 才发 POST —— 千万别混用。**
> 往集合 URL 发 PATCH 只会拿到 **`405`**（方法未注册），而不是你期望的 `400`。
> 例如 `/redfish/v1/AccountService/Accounts/` 只注册了 **HEAD / GET / POST**
> （`account_service.hpp:2342-2354`），所以行42 的"创建用户"负向用例必须用 `C`。

### 0.4 先查出所有运行时 ID

> 若已 `source biz_env.sh`，**这一步已经自动做完**了 —— 它会把 `CID` / `ETH` / `SID` / `FW`
> 直接打印出来并导出到当前 shell；换板子后重新跑一次 `discover` 即可。
> 手工版如下（效果等价）：

```bash
G /redfish/v1/Chassis/ | jq -r '.Members[]["@odata.id"]'
CID=$(G /redfish/v1/Chassis/ | jq -r '.Members[0]["@odata.id"] | split("/")[-1]')
echo "CHASSIS_ID = $CID"

G /redfish/v1/Managers/bmc/EthernetInterfaces/ | jq -r '.Members[]["@odata.id"]'
ETH=$(G /redfish/v1/Managers/bmc/EthernetInterfaces/ \
      | jq -r '.Members[]["@odata.id"] | split("/")[-1] | select(contains("_")|not)' | head -1)
echo "ETH = $ETH"
```

### 0.5 状态码判读总表

| HTTP | 含义 | 判定 |
|---|---|---|
| `200` | 读取成功 / 动作已同步完成 | ✅ |
| `201` | 资源已创建（响应带 `Location` 头） | ✅ |
| `204` | 写入成功无返回体 | ✅ |
| `400` + `propertyUnknown` | 请求里有多余的键名（拼错了） | ❌ 对照本手册的键名 |
| `400` + `propertyValueIncorrect` | 值非法（负向用例里这是 ✅） | 看用例 |
| `404` + `resourceNotFound` | 资源 ID 写错 | ❌ 用集合接口查真实 ID |
| `404` + 空响应体 | **路由根本没注册**（编译期关闭） | 见 §0.2 |
| `405` | 该方法未在这个 URL 上注册 | ❌ 检查 `.methods()` |
| `415` + `unsupportedMediaType` | `Content-Type` 不被该端点接受（仅行47 的 multipart 端点） | 见 §九 |
| `501` + `queryParameterValueFormatError` | 用了未启用的 `$` 查询参数（如 `$expand`） | 见 §0.2 |
| `501` + `propertyNotWritable` | 只读属性被写（负向用例里这是 ✅） | 看用例 |
| `403` | 权限不足 | 换管理员账号 |

### 0.6 排错三件套

```bash
ssh root@$BMC 'journalctl -u bmcweb -f'        # 实时日志
ssh root@$BMC 'bmcweb loglevel debug'          # 打开 DEBUG（不重启）
ssh root@$BMC 'bmcweb loglevel ERROR'          # 恢复默认
```

改代码后部署：

```bash
devtool build bmcweb && devtool deploy-target bmcweb root@$BMC
ssh root@$BMC 'systemctl restart bmcweb'
```

---

# 一、Chassis 传感器（业务行 5 / 6 / 7）

## 行5 — 传感器列表

**测试逻辑**
这是行6/7 的**前置门禁**。它要证明三件事：
1. 该 Chassis 下确实挂着 `Sensors` 集合（EntityManager 配好了传感器）；
2. 集合能被枚举（`Members` 是数组，`@odata.count` 与实际一致）；
3. **每个成员 ID 都是合法格式** —— bmcweb 的传感器 ID 必须是 `<type>_<name>`（**含下划线**），对应 D-Bus 路径
   `/xyz/openbmc_project/sensors/<type>/<name>`。单条 GET 时
   `sensor_utils::splitSensorNameAndType()`（`sensor_utils.hpp:175-191`）
   **在第一个 `_` 处切分**（`substr(0,index)` 是 type，`substr(index+1)` 是 name），
   切不出来就 `resourceNotFound` → **不带下划线的 ID 会直接 404**。这是最容易踩的坑。
   > 特例：`fantach_xxx` / `fanpwm_xxx` 会在第 3 位插回一个 `_` 变成 `fan_tach`，
   > 以匹配 D-Bus 上的 `/xyz/openbmc_project/sensors/fan_tach/...`。所以看到
   > `fan_tach_Fan1` 这种 ID 不要以为是命名不规范。

**测试方法**

```bash
CID=$(G /redfish/v1/Chassis/ | jq -r '.Members[0]["@odata.id"] | split("/")[-1]')
G "/redfish/v1/Chassis/$CID/Sensors/" | jq .
```

**例子（期望响应）**

```json
{
  "@odata.id": "/redfish/v1/Chassis/cdu/Sensors",
  "@odata.type": "#SensorCollection.SensorCollection",
  "Name": "Sensors",
  "Members@odata.count": 3,
  "Members": [
    { "@odata.id": "/redfish/v1/Chassis/cdu/Sensors/temperature_CPU0Temp" },
    { "@odata.id": "/redfish/v1/Chassis/cdu/Sensors/fan_Fan1" },
    { "@odata.id": "/redfish/v1/Chassis/cdu/Sensors/voltage_P12V" }
  ]
}
```

**判据（jq 断言，可粘贴）**

```bash
G "/redfish/v1/Chassis/$CID/Sensors/" > /tmp/s.json
jq -e '.Members|type == "array"' /tmp/s.json                          # 集合可枚举
jq -e 'has("Members@odata.count")' /tmp/s.json                        # 计数存在
jq -e '[.Members[]["@odata.id"]|split("/")[-1]|contains("_")]|all' /tmp/s.json   # 全部都含下划线
jq -e '."Members@odata.count" == (.Members|length)' /tmp/s.json       # 计数与数组长度一致
```

**失败排查**
- `404` → `CHASSIS_ID` 错，回 §0.4 重查；
- `Members` 为空数组 → EntityManager 没为这块 Chassis 配传感器（配置问题，不是 bmcweb bug）；
- 某个 ID 不含下划线 → 该传感器在 EntityManager 里的命名不合规，单条 GET 必 404。

---

## 行6 — 获取全部传感器读数

**测试逻辑**
业务想要"一次拿到所有读数"。标准 Redfish 的做法是 `?$expand=.($levels=1)`，
**但本 build `BMCWEB_INSECURE_ENABLE_REDFISH_QUERY=false`，`$expand`/`$filter` 被编译关闭**
（`redfish-core/include/utils/query_param.hpp:403` 与 `:451` 的条件都是
`it.key == "$expand" && BMCWEB_INSECURE_ENABLE_REDFISH_QUERY`）。

关掉之后**不是静默忽略**，而是掉进 `else` 分支（`query_param.hpp:462-472`）：
只要键名以 `$` 开头且没被上面任何分支接住，就返回
**`501 Not Implemented` + `queryParameterValueFormatError`**。

所以有两条路：
- **路线 A（验证现状）**：确认 `$expand` 返回 **501** —— 证明这不是服务坏了，而是编译选项没开；
- **路线 B（实际拿数据）**：客户端按 `Members` 逐个 GET 再聚合。

**测试方法 —— 路线 A：验证 `$expand` 被禁用**

```bash
S "$BASE/redfish/v1/Chassis/$CID/Sensors/?%24expand=.(%24levels%3D1)" ; echo
# 注意 $ 在 URL 里要写成 %24，否则被 shell 吃掉
cat /tmp/last_body | jq -c '.error.code'
```

期望：`501`，错误码 `Base.1.19.QueryParameterValueFormatError`。
如果返回 200，说明本 build 打开了该选项（与 §0.2 不符，需复核编译参数）。

**测试方法 —— 路线 B：客户端聚合（推荐）**

```bash
CID=$(G /redfish/v1/Chassis/ | jq -r '.Members[0]["@odata.id"] | split("/")[-1]')
G "/redfish/v1/Chassis/$CID/Sensors/" | jq -r '.Members[]["@odata.id"]' | while read -r u; do
    G "$u" | jq -r '"\(.Name)\t\(.Reading // "null")\t\(.ReadingUnits // .ReadingType // "-")\t\(.Status.State)"'
done | column -t -s $'\t'
```

**例子（期望输出）**

```
CPU0 Temp        45.0    Cel            Enabled
Fan1             7800    RPM            Enabled
P12V             12.04   V              Enabled
```

**判据**
- 每个传感器 GET 都返回 `200`；
- 打印出的行数与行5 的 `Members@odata.count` 一致；
- 至少有一部分传感器 `Reading` 非 `null`（全部为 `null` 说明底层 D-Bus 传感器服务没起来）。

**失败排查**
- 个别传感器 404 → 该 ID 命名不合规（见行5）；
- 全部 `Reading=null` → 底层 `xyz.openbmc_project.Sensor.Value` 无数据，检查 `phosphor-hwmon` / `dbus-sensors` 是否在跑：
  `ssh root@$BMC 'busctl tree xyz.openbmc_project.HwmonTempSensor | head -30'`

---

## 行7 — 获取单个传感器

**测试逻辑**
验证单条 Sensor 资源的**字段完整性**与**数值真实性**：
1. 结构字段：`@odata.id` / `Name` / `Status`；
2. 读数字段：`Reading` + (`ReadingUnits` 或 `ReadingType`)；
3. 阈值字段：`Thresholds/{UpperCaution,UpperCritical,LowerCaution,LowerCritical,UpperFatal,LowerFatal}/Reading`（仅部分类型有）；
4. **与 D-Bus 原值交叉比对**，确认 bmcweb 没做错误换算。

**关键认知：`Reading` 允许是 `null`**
`Reading` 这个**键一定存在**，但传感器当前不可用（未插、未就绪）时值就是 `null`
（`sensor_utils.hpp:573` 明确写 `sensorJson["Reading"] = nullptr;`）。
此时 `Status.State` 会是 `Absent` / `UnavailableOffline`。
**这是符合 Redfish 规范的现象，不要判为失败。**

**测试方法**

```bash
SID=$(G "/redfish/v1/Chassis/$CID/Sensors/" | jq -r '.Members[0]["@odata.id"] | split("/")[-1]')
G "/redfish/v1/Chassis/$CID/Sensors/$SID/" | jq .
```

**例子（期望响应）**

```json
{
  "@odata.id": "/redfish/v1/Chassis/cdu/Sensors/temperature_CPU0Temp",
  "@odata.type": "#Sensor.v1_11_1.Sensor",
  "Id": "temperature_CPU0Temp",
  "Name": "CPU0 Temp",
  "Reading": 45.0,
  "ReadingUnits": "Cel",
  "ReadingType": "Temperature",
  "Status": { "State": "Enabled", "Health": "OK" },
  "Thresholds": {
    "UpperCaution":  { "Reading": 85.0 },
    "UpperCritical": { "Reading": 95.0 }
  }
}
```

> 温度类传感器 `@odata.type` 可能是 `#Thermal.v1_3_0.Temperature`；
> 风扇是 `#Thermal.v1_3_0.Fan`（`ReadingUnits` = `RPM` 或 `Percent`）；
> 电压是 `#Power.v1_0_0.Voltage`。**都属正常**，断言不要写死某一种。

**判据**

```bash
G "/redfish/v1/Chassis/$CID/Sensors/$SID/" > /tmp/one.json
jq -e 'has("Name")'                            /tmp/one.json    # 名称
jq -e 'has("Reading")'                         /tmp/one.json    # 读数键存在（值可为 null）
jq -e 'has("ReadingUnits") or has("ReadingType")' /tmp/one.json # 至少一个单位/类型字段
jq -e '.Status.State | test("^(Enabled|Disabled|Absent|UnavailableOffline|StandbyOffline|Testing)$")' /tmp/one.json
```

**交叉验证（强烈建议做一次，证明数据没被篡改）**

```bash
# bmcweb 的 sensor id 是 <type>_<name>，对应 D-Bus 路径 /xyz/openbmc_project/sensors/<type>/<name>
ssh root@$BMC "busctl introspect xyz.openbmc_project.HwmonTempSensor \
  /xyz/openbmc_project/sensors/temperature/CPU0Temp \
  xyz.openbmc_project.Sensor.Value | grep -E 'Value|Unit'"
```

若 D-Bus 里 `Value` = `45.0`，而 Redfish `Reading` = `45.0`，则换算正确。

---

# 二、EventService 订阅（业务行 13 / 38 / 15）

> 这三条是**一个闭环**：列表 → 创建 → 回读 → 删除 → 确认消失。
> 建议连着做，一次验证完整 CRUD 能力。

## 行13 — 订阅列表

**测试逻辑**
告警接收者（Event Destination）集合的可读性。这是后续写操作的前置：
先确认集合本身能列，再创建，才能排除"集合路由坏了"的干扰。

**测试方法 / 例子**

```bash
G /redfish/v1/EventService/Subscriptions/ | jq .
```

```json
{
  "@odata.id": "/redfish/v1/EventService/Subscriptions",
  "@odata.type": "#EventDestinationCollection.EventDestinationCollection",
  "Name": "Event Subscriptions Collection",
  "Members@odata.count": 1,
  "Members": [
    { "@odata.id": "/redfish/v1/EventService/Subscriptions/1" }
  ]
}
```

**判据**：`200` + `.Members|type == "array"` + `has("Members@odata.count")`。

---

## 行38 — 创建告警接收者

**测试逻辑**
验证 bmcweb 能否把一条订阅**落到 D-Bus**（`xyz.openbmc_project.eventservice.Subscription`）并回读一致。
要检查四件事：
1. `POST` 返回 `201` 且**响应头带 `Location`**（指向新资源）；
2. `Destination` 原样回读；
3. **`Protocol` 只能是 `"Redfish"`** —— 要么省略（bmcweb 从 URL scheme `https://` 推导，`crow::utility::setProtocolDefaults`），要么显式写 `"Redfish"`。写别的值会被明确拒绝（`event_service.hpp:515`：`if (protocol != "Redfish")` → `propertyValueNotInList`）；
4. `Context` 原样回读。

**关键坑：`SubscriptionType` 只接受字面量 `"RedfishEvent"`**
`event_service.hpp:499-513`：若提供了该键且 `!= "RedfishEvent"` → 400；
**最省事的做法是直接省略这个键**（默认就是 `RedfishEvent`）。

**请求体白名单（`event_service.hpp:341-356`，多余的键会 400 `propertyUnknown`）**

```text
Context                    Destination            HeartbeatIntervalMinutes   MessageIds
OriginResources            RegistryPrefixes       SendHeartbeat              SubscriptionType
DeliveryRetryPolicy        EventFormatType        HttpHeaders                MetricReportDefinitions
Protocol                   ResourceTypes          VerifyCertificate
```

**测试方法**

```bash
BODY='{"Destination":"https://192.168.1.200:443/redfish-event",
       "Protocol":"Redfish",
       "Context":"biz-api-check"}'

# 创建订阅（POST → 用 C；它会自动打印 Location 头）
C "/redfish/v1/EventService/Subscriptions/" "$BODY"
```

**例子（期望响应）**

```
HTTP 201
Location: /redfish/v1/EventService/Subscriptions/1234567890
```

```json
{
  "@odata.id": "/redfish/v1/EventService/Subscriptions/1234567890",
  "Id": "1234567890",
  "Destination": "https://192.168.1.200:443/redfish-event",
  "Protocol": "Redfish",
  "Context": "biz-api-check",
  "SubscriptionType": "RedfishEvent"
}
```

**回读验证**

```bash
SUB=$(grep -i '^Location' /tmp/last_hdr | awk -F': ' '{print $2}' | tr -d '\r\n')
G "$SUB" | jq '{d:.Destination, p:.Protocol, c:.Context, t:.SubscriptionType}'
```

**判据**
- `201` + 有 `Location` 头；
- `.Destination` 与请求完全一致；
- `.Protocol == "Redfish"`；
- `.Context` 与请求一致。

**常见失败**
- `400 propertyValueNotInList` 指向 `SubscriptionType` → 值不是 `RedfishEvent`，删掉该键重试；
- `400 propertyValueNotInList` 指向 `Protocol` → 写了非 `"Redfish"` 的值（`event_service.hpp:515`），删掉该键让 bmcweb 从 URL 推导即可；
- `400 propertyValueFormatError` 指向 `Destination` → 必须是**绝对 URI**（含 scheme），长度 ≤ 2000，端口合法，且**不能带 userinfo**（`https://u:p@host` 会被拒）；
- `400 stringValueTooLong` 指向 `Context` → 上限 256 字符（`event_service.hpp:549`）；
- `400 propertyValueConflict` 指向 `Context` 与 `Protocol` → 只有当 `Protocol=SNMPv2c` 时才会出现（那是另一条 SNMP trap 分支）；
- **订阅创建后 bmcweb 会向 `Destination` 发心跳**，对端没有服务在听只会在 BMC 日志里留警告，**不影响创建成功**。

---

## 行15 — 删除告警接收者

**测试逻辑**
验证订阅能被彻底移除：`DELETE` → `204` → **再 GET 必须 404**。
只看到 `204` 是不够的 —— 必须回读确认资源真的消失了（防止实现只改了状态没删数据）。

**测试方法 / 例子**

```bash
S -X DELETE "$BASE$SUB"        # 期望 204
S "$BASE$SUB"                  # 期望 404

# 确认集合里也没了
G /redfish/v1/EventService/Subscriptions/ | jq -c '.Members'
```

**判据**：`DELETE` 返回 `204`，随后 GET 返回 `404`，且集合 `Members` 中不再包含该 URI。

---

# 三、Managers / 以太网口 —— 只读项（业务行 17 / 22–32）

> 业务行 22–32 是**同一个资源**（`/redfish/v1/Managers/bmc/EthernetInterfaces/<eth>`）
> 的不同属性。一次 GET 就能全部验证，不需要发 11 个请求。

## 行17 — Host Name（读取）

**测试逻辑**：主机名是最基础的网络属性，也是行33（写）的基线。先读出去当前值，后面写测试才有"还原点"。

## 行22–25 — IPv4 地址 / 掩码 / 网关 / DNS

**测试逻辑**
验证 IPv4 视图的**结构正确性**。要点：
- `IPv4Addresses` 是**数组**（可能同时有静态 + DHCP 地址）；
- `SubnetMask` 是**点分十进制**（如 `255.255.255.0`），不是前缀长度；
- `Gateway` 在**数组元素内部**（不是顶层），且**未配置时是空字符串**（不是 null，也不是缺失）；
- `NameServers` 是**顶层**数组，且只在**至少有一个地址**时才出现。

## 行27 — DHCPv4 使能

**测试逻辑**：`DHCPv4.OperatingMode` 的枚举是 `Enabled` / `Disabled`。
这是判断"当前 IP 是静态还是动态"的唯一依据 —— **测行35（改静态 IP）之前必须先看这个值**，如果是 `Enabled`，直接 PATCH 静态地址会导致 BMC 断网。

## 行28–32 — IPv6 地址 / 前缀长度 / 网关 / DNS / DHCPv6

**测试逻辑**
IPv6 的字段形态和 IPv4 **不一样**，这是最容易写错断言的地方：
- `IPv6Addresses[].PrefixLength` 是**整数**（如 `64`），不是掩码字符串；
- `IPv6Addresses[]` 还可能带 `AddressOrigin`（`Static` / `SLAAC` / `DHCP`）；
- IPv6 默认网关叫 **`IPv6DefaultGateway`**（顶层单数字符串），**不是**数组；
- IPv6 的 `DHCPv6.OperatingMode` 是 `Enabled` / `Disabled`，另有两个派生布尔：`UseDNSServers`、`UseNTPServers`。

**统一测试方法**

```bash
ETH=$(G /redfish/v1/Managers/bmc/EthernetInterfaces/ \
      | jq -r '.Members[]["@odata.id"] | split("/")[-1] | select(contains("_")|not)' | head -1)
U="/redfish/v1/Managers/bmc/EthernetInterfaces/$ETH"
G "$U" > /tmp/eth.json
jq . /tmp/eth.json
```

**例子（期望响应，节选）**

```json
{
  "@odata.id": "/redfish/v1/Managers/bmc/EthernetInterfaces/eth0",
  "@odata.type": "#EthernetInterface.v1_12_0.EthernetInterface",
  "Id": "eth0",
  "Name": "eth0",
  "HostName": "cdu-bmc",
  "FQDN": "cdu-bmc.local",
  "MACAddress": "02:00:00:00:00:01",
  "InterfaceEnabled": true,

  "DHCPv4": { "DHCPEnabled": true, "OperatingMode": "Enabled",
              "UseDomainName": true },
  "IPv4Addresses": [
    { "Address": "192.168.1.100",
      "SubnetMask": "255.255.255.0",
      "Gateway": "192.168.1.1",
      "AddressOrigin": "DHCP" }
  ],
  "NameServers": ["192.168.1.1", "8.8.8.8"],

  "DHCPv6": { "OperatingMode": "Disabled", "UseDNSServers": true,
              "UseNTPServers": true, "UseDomainName": true },
  "IPv6Addresses": [
    { "Address": "fe80::1",
      "PrefixLength": 64,
      "AddressOrigin": "SLAAC" }
  ],
  "IPv6DefaultGateway": "",
  "IPv6AddrPolicy": "PreferPublic",

  "VLAN": { "VLANEnable": false, "VLANId": 0, "Tagged": false },
  "StaticNameServers": []
}
```

**判据（一条命令全查）**

```bash
jq -e '
  (.HostName|type=="string")                                                    and   # 行17
  (.IPv4Addresses|type=="array")                                                and   # 行22
  (.IPv4Addresses[0].SubnetMask|test("^[0-9]+(\\.[0-9]+){3}$"))                  and   # 行23
  (.IPv4Addresses[0].Gateway|type=="string")                                    and   # 行24
  ((has("NameServers")|not) or (.NameServers|type=="array"))                    and   # 行25
  (.DHCPv4.OperatingMode|test("^(Enabled|Disabled)$"))                          and   # 行27
  (.IPv6Addresses|type=="array")                                                and   # 行28
  (.IPv6Addresses[0].PrefixLength|type=="number")                               and   # 行29
  (.IPv6DefaultGateway|type=="string")                                          and   # 行30
  (.DHCPv6.OperatingMode|test("^(Enabled|Disabled)$"))                          and   # 行32
  (.VLAN.VLANEnable|type=="boolean")                                                  # 行44 读侧
' /tmp/eth.json && echo "行17/22-32 全部通过"
```

**交叉验证（与 D-Bus 对比，证明没走样）**

```bash
ssh root@$BMC "busctl get-property xyz.openbmc_project.Network \
  /xyz/openbmc_project/network/eth0 \
  xyz.openbmc_project.Network.EthernetInterface \
  DHCPEnabled HostName"
```

**常见失败**
- `NameServers` 键不存在 → DHCP 没下发 DNS 且没配静态 DNS，**属正常**（所以断言要写成"要么没有要么是数组"）；
- `IPv4Addresses[0].Gateway` 是 `""` → 该地址没网关，**属正常**；
- `404 resourceNotFound` → `ETH` 取错了（比如取到了 VLAN 子接口 `eth0_42`），过滤掉含下划线的即可。

---

# 四、Managers / 以太网口 —— 写入项（业务行 33 / 34 / 35 / 36）

> **统一套路：读原值 → PATCH → 回读确认 → 立刻还原。**
> 四条里只有行35 不能真改（见下）。

## 行33 — 改 Host Name

**测试逻辑**
验证 `PATCH` 生效并返回 `204`，且值真的落到 D-Bus。
HostName 是**单标签**（不含点），改了之后 `/etc/hostname` 与 systemd 主机名都会变。

**测试方法**

```bash
U="/redfish/v1/Managers/bmc/EthernetInterfaces/$ETH"
ORIG=$(G "$U" | jq -r .HostName)          # ① 存原值
echo "原 HostName = $ORIG"

P "$U" '{"HostName":"cdu-test-01"}'       # ② 改；期望 204
G "$U" | jq -r .HostName                   # ③ 回读；期望 cdu-test-01

P "$U" "{\"HostName\":\"$ORIG\"}"         # ④ 立刻还原
G "$U" | jq -r .HostName                   # 确认已还原
```

**判据**：PATCH 返回 `204`；回读值与写入值一致。

**常见失败**
- `400 propertyValueFormatError` → HostName 里有点或非法字符（点会走到行34 的 FQDN 分支）；
- `400 propertyUnknown` → 键名拼错（是 `HostName`，不是 `Hostname`）。

---

## 行34 — 改 FQDN

**测试逻辑**
`ethernet.hpp:1292` 的 `handleFqdnPatch()` 处理 FQDN 的方式是：

> **按第一个 `.` 拆成两半 —— 前半写 HostName，后半写 DomainName。**
> 源码即 `pos = fqdn.find('.')`；`hostname = fqdn.substr(0,pos)`；
> `domainname = fqdn.substr(pos+1)`，然后分别调
> `handleHostnamePatch()` 与 `handleDomainnamePatch()`。

所以：
1. FQDN **必须含至少一个点**，否则 `fqdn.find('.') == npos` → `400 PropertyValueFormatError`；
2. FQDN 总长 **≤ 255**（RFC 1035），超了同样是 `PropertyValueFormatError`；
3. **改 FQDN 会顺带改掉 HostName** —— 这两个是同一份 D-Bus 数据的两种视图，不是独立字段；
4. 对 `a.b.c` 这种多段 FQDN，拆分是 `HostName=a`、`DomainName=b.c`（只切第一个点）。

**测试方法**

```bash
U="/redfish/v1/Managers/bmc/EthernetInterfaces/$ETH"
ORIG_FQDN=$(G "$U" | jq -r .FQDN)
ORIG_HOST=$(G "$U" | jq -r .HostName)

P "$U" '{"FQDN":"biztest.local"}'         # 期望 204
G "$U" | jq '{HostName, FQDN}'            # 期望 HostName=biztest, FQDN=biztest.local

# 负向：不带点，必须被拒
P "$U" '{"FQDN":"nodot"}'                 # 期望 400

# 还原
P "$U" "{\"FQDN\":\"$ORIG_FQDN\"}"
G "$U" | jq -r .HostName                   # 确认已回到 $ORIG_HOST
```

**例子（期望响应）**

```json
{ "HostName": "biztest", "FQDN": "biztest.local" }
```

**判据**
- 第一次 PATCH → `204`，回读 `.FQDN == "biztest.local"` **且 `.HostName == "biztest"`**（证明拆分行为）；
- 不带点的 PATCH → `400`；
- 还原后 `.HostName` 回到原值。

---

## 行35 — 改静态 IP（⚠️ 危险，只做负向校验）

**测试逻辑**
**不要真改。** 一旦写入成功，BMC 可能在几秒内换 IP，你的 SSH/curl 会话直接断开，只能靠串口救回来。

正确的做法是**只验证入参校验分支**：发一个**明显非法**的子网掩码，期望 bmcweb 在写入 D-Bus **之前**就返回 `400`。如果它返回了 400，就证明：
- 路由存在；
- 参数解析分支跑了；
- `parseAddresses()` 的校验逻辑生效（`ethernet_test.cpp` 里的 `conflictingGateways*` 用例也是测这个）。

**测试方法**

```bash
U="/redfish/v1/Managers/bmc/EthernetInterfaces/$ETH"

# ① 先确认当前是 DHCP 还是 Static（决定要不要继续）
G "$U" | jq '{mode:.DHCPv4.OperatingMode, addrs:[.IPv4Addresses[].AddressOrigin]}'

# ② 负向：非法子网掩码，必须被拒
P "$U" '{"IPv4StaticAddresses":[{"Address":"10.99.99.99","SubnetMask":"255.255.255.999"}]}'
# 期望 400 + propertyValueFormatError

# ③ 负向：两个地址冲突的网关，必须被拒
P "$U" '{"IPv4StaticAddresses":[
    {"Address":"10.99.99.10","SubnetMask":"255.255.255.0","Gateway":"10.99.99.1"},
    {"Address":"10.99.99.11","SubnetMask":"255.255.255.0","Gateway":"10.99.99.2"}]}'
# 期望 400（conflictingGatewaysNew 的逻辑）

# ④ 确认 BMC 网络没被改坏
curl -sk -o /dev/null -w '%{http_code}\n' "$BASE/redfish/v1/"
```

**例子（期望响应）**

```json
{
  "error": {
    "code": "Base.1.19.PropertyValueFormatError",
    "message": "The value '255.255.255.999' for the property SubnetMask is not in a valid format",
    "@Message.ExtendedInfo": [{
      "MessageId": "Base.1.19.PropertyValueFormatError",
      "MessageArgs": ["255.255.255.999", "SubnetMask"]
    }]
  }
}
```

**判据**：两次负向 PATCH 都返回 `400`；步骤④ 仍然 `200`（网络没坏）。

> 如果**必须**验证真正写入静态 IP（例如产线验收），正确流程是：
> 接到**串口/带外**控制台 → 改 IP → 从串口确认能 ping 通新 IP → 再从串口改回 DHCP。
> 绝对不要在只有 HTTP 通道的情况下做这件事。

---

## 行36 — 改静态 DNS

**测试逻辑**
要区分两个字段：
- `NameServers` —— **当前实际生效**的 DNS（可能是 DHCP 下发的，只读）；
- `StaticNameServers` —— **用户手动配置**的 DNS（可写）。

PATCH `StaticNameServers` 成功后，`NameServers` 会变成你配的值。清空 `StaticNameServers`（写 `[]`）会退回 DHCP 下发。
这条相对安全（改错 DNS 只是解析不了域名，不会断连），可以放心做读写闭环。

**测试方法**

```bash
U="/redfish/v1/Managers/bmc/EthernetInterfaces/$ETH"
ORIG=$(G "$U" | jq -c '.StaticNameServers // []')

P "$U" '{"StaticNameServers":["9.9.9.9"]}'        # 期望 204
G "$U" | jq -c '{static:.StaticNameServers, active:.NameServers}'
# 期望 { static: ["9.9.9.9"], active: ["9.9.9.9"] }

P "$U" "{\"StaticNameServers\":$ORIG}"            # 还原（通常就是 []）
```

**判据**
- PATCH → `204`；
- `.StaticNameServers == ["9.9.9.9"]`；
- `.NameServers` 也变成 `["9.9.9.9"]`（证明生效）；
- 还原后 `NameServers` 回到 DHCP 下发的值。

---

# 五、Managers / NTP（业务行 37）

**测试逻辑**
NTP 配置挂在 `NetworkProtocol` 资源上（不是 EthernetInterface）。

**键名对照（务必照抄，写错会 400 `propertyUnknown`）**

| 请求体 JSON | bmcweb 内部 JSON Pointer | 可写？ |
|---|---|---|
| `NTP.NTPServers`（数组） | `"NTP/NTPServers"`（`network_protocol.hpp:496`） | ✅ 写入 D-Bus `StaticNTPServers` |
| `NTP.ProtocolEnabled`（布尔） | `"NTP/ProtocolEnabled"`（`network_protocol.hpp:497`） | ✅ 见下 |
| `NTP.NetworkSuppliedServers` | 读取时由 D-Bus `NTPServers` 填充（`:232-234`） | ❌ 只读 |
| `NTPEnable` | —— | ❌ **不存在这个键** |

**`ProtocolEnabled` 是可写的，但语义和你想的不一样**
它不是"是否启用 NTP 服务"，而是 **`timedate1` 的 NTP 同步开关**
（`network_protocol.hpp:278-288` 的 `handleNTPProtocolEnabled` → D-Bus
`org.freedesktop.timedate1.SetNTP`）。改成 `false` 后 BMC 主机**不再自动对时**，
这会影响日志时间戳与证书校验，**测完必须还原**。

读取侧的值来自 `org.freedesktop.timedate1` 的 `NTP` 属性（`:445-459`）。

**测试方法**

```bash
NP="/redfish/v1/Managers/bmc/NetworkProtocol"

# ① 读现状（记下 ProtocolEnabled 作为还原点）
G "$NP" > /tmp/np.json
jq '{enabled:.NTP.ProtocolEnabled,
     servers:.NTP.NTPServers,
     networkSupplied:.NTP.NetworkSuppliedServers,
     port:.NTP.Port}' /tmp/np.json

# ② 改 NTP 服务器列表（存原值）
ORIG_SRV=$(jq -c '.NTP.NTPServers // []' /tmp/np.json)
P "$NP" '{"NTP":{"NTPServers":["ntp.biztest.local","10.10.10.10"]}}'   # 期望 204

# ③ 回读
G "$NP" | jq -c .NTP.NTPServers        # 期望 ["ntp.biztest.local","10.10.10.10"]

# ④ 还原服务器列表
P "$NP" "{\"NTP\":{\"NTPServers\":$ORIG_SRV}}"

# ⑤ 切换协议开关（可选；务必还原！）
ORIG_EN=$(jq -r '.NTP.ProtocolEnabled' /tmp/np.json)
P "$NP" '{"NTP":{"ProtocolEnabled":false}}'          # 期望 204
G "$NP" | jq -r .NTP.ProtocolEnabled                 # 期望 false
ssh root@$BMC 'timedatectl show -p NTP'              # 期望 NTP=no —— 交叉验证
P "$NP" "{\"NTP\":{\"ProtocolEnabled\":$ORIG_EN}}"   # 还原
ssh root@$BMC 'timedatectl show -p NTP'              # 确认已还原
```

**例子（期望响应）**

```json
{
  "NTP": {
    "ProtocolEnabled": true,
    "NTPServers": ["ntp.biztest.local", "10.10.10.10"],
    "NetworkSuppliedServers": [],
    "Port": 123
  }
}
```

**判据**
- `GET` → `200`，`.NTP.ProtocolEnabled` 为布尔，`.NTP.NTPServers` 为数组；
- PATCH `NTPServers` → `204`，回读一致；
- PATCH `ProtocolEnabled` → `204`，且 `timedatectl show -p NTP` 同步变化（证明真的落到了 D-Bus）；
- 两个负向用例：写 `{"NTP":{"NTPEnable":true}}` 或 `{"NTP":{"NetworkSuppliedServers":[]}}` → `400 propertyUnknown`（证明白名单生效）。

**交叉验证**

```bash
ssh root@$BMC 'busctl get-property org.freedesktop.timedate1 \
  /org/freedesktop/timedate1 org.freedesktop.timedate1 NTP'
ssh root@$BMC 'timedatectl show-timesync --all | grep -E "ServerName|NTPMessage"'
```

---

# 六、日志（业务行 20 / 21 / 43）

## 行20 — BMC 登录/系统日志（Journal）

**测试逻辑**
验证三层结构：
1. `LogServices` 集合里**确实注册了 `Journal` 服务**；
2. `Journal/Entries` 是标准 `LogEntryCollection`（`@odata.type` 正确、`Members` 是数组）；
3. 单条 Entry 的**必需字段齐全**：`Message` / `Created` / `EntryType`。

本 build `BMCWEB_REDFISH_BMC_JOURNAL=true`，所以这条可用。

**测试方法**

```bash
# ① 服务列表里必须有 Journal
G /redfish/v1/Managers/bmc/LogServices/ \
  | jq -c '[.Members[]["@odata.id"]]|map(select(test("Journal")))'
# 期望 ["/redfish/v1/Managers/bmc/LogServices/Journal"]

# ② 集合
G /redfish/v1/Managers/bmc/LogServices/Journal/Entries/ \
  | jq '{type:."@odata.type", count:."Members@odata.count"}'

# ③ 单条
JID=$(G /redfish/v1/Managers/bmc/LogServices/Journal/Entries/ | jq -r '.Members[0]["@odata.id"]')
G "$JID" | jq .
```

**例子（期望响应）**

```json
{
  "@odata.id": "/redfish/v1/Managers/bmc/LogServices/Journal/Entries/2026-09-30T08:12:33Z",
  "@odata.type": "#LogEntry.v1_15_0.LogEntry",
  "Id": "2026-09-30T08:12:33Z",
  "Name": "Journal Entry",
  "EntryType": "Event",
  "Severity": "OK",
  "Created": "2026-09-30T08:12:33Z",
  "Message": "bmcweb started"
}
```

**判据**
- 步骤① 输出含 `Journal`；
- 集合 `@odata.type == "#LogEntryCollection.LogEntryCollection"`，`Members` 是数组；
- 单条 `.Message` / `.Created` / `.EntryType == "Event"` 非空；
- 条目 `Id` 是 **ISO8601 时间戳**（bmcweb 用日志时间戳当 ID）。

**顺带验一下分页参数（`$top` / `$skip` 是启用的，与 `$expand` 不同）**

```bash
G "/redfish/v1/Managers/bmc/LogServices/Journal/Entries/?%24top=2" \
  | jq '{count:."Members@odata.count", returned:(.Members|length)}'
# 期望：Members 数量 <= 2（证明 $top 生效）

S "$BASE/redfish/v1/Managers/bmc/LogServices/Journal/Entries/?%24top=99999" ; echo
# 期望 400 queryParameterOutOfRange（超过 Query::maxTop）
```

**常见失败**
- `404` → `BMCWEB_REDFISH_BMC_JOURNAL=false`（本 build 是 `true`，若 404 说明 build 参数被改了）；
- `500` → journald 不可访问，检查 `ssh root@$BMC 'journalctl -n 1'`。

---

## 行21 — 硬件事件日志

**测试逻辑**
和行20 结构完全一样，只是数据源不同（来自 `phosphor-logging` 的 D-Bus 对象
`xyz.openbmc_project.Logging.Entry`，而非 journald）。

**路由固定走 `Systems` —— 这是编译期决定的，不是运行期**
本 build `BMCWEB_REDFISH_EVENTLOG_LOCATION="systems"`，所以：

| 代码位置 | 效果 |
|---|---|
| `log_services.hpp:905-914` | `if constexpr (EVENTLOG_LOCATION=="systems" && !MULTI_COMPUTER_SYSTEM)` → **Systems 的 LogServices 集合里加入 `EventLog`** |
| `log_services.hpp:1019-1027` | `if constexpr (EVENTLOG_LOCATION=="managers")` → **Managers 集合里**不加入 EventLog（本 build 该分支为假） |
| `systems_logservices_dbus_eventlog.hpp:198/204` | 注册 `/redfish/v1/Systems/<str>/LogServices/EventLog/Entries[/<str>]/` |

另外本 build `REDFISH_HOST_LOGGER=false`（`HostLogger` 不注册）、
`DUMP_LOG=false`（`Dump` 不注册）、`CPU_LOG=false`（`Crashdump` 不注册），
所以 Systems 的 `LogServices` 集合里**只会有 `EventLog`**。

**测试方法**

```bash
# ① Systems 的 LogServices 集合里必须恰好有 EventLog
G /redfish/v1/Systems/system/LogServices/ \
  | jq -c '{type:."@odata.type", members:[.Members[]["@odata.id"]]}'

# ② Entries 集合
G /redfish/v1/Systems/system/LogServices/EventLog/Entries/ \
  | jq '{type:."@odata.type", count:."Members@odata.count"}'

# ③ 单条
EID=$(G /redfish/v1/Systems/system/LogServices/EventLog/Entries/ | jq -r '.Members[0]["@odata.id"]')
[ "$EID" != "null" ] && G "$EID" | jq . || echo "无事件（空集合，也算通过）"
```

**例子（期望响应）**

```json
{
  "@odata.type": "#LogEntry.v1_15_0.LogEntry",
  "Id": "1",
  "Name": "Log Entry 1",
  "EntryType": "Event",
  "Severity": "Warning",
  "Created": "2026-09-29T21:04:11+00:00",
  "Message": "Power supply PSU1 lost input",
  "SensorType": "Power Supply / Converter"
}
```

**判据**
- 步骤① 的 `members` 里含 `/redfish/v1/Systems/system/LogServices/EventLog`；
- 步骤② 集合 `200`，`@odata.type == "#LogEntryCollection.LogEntryCollection"`；
- 步骤③ `.Message` / `.Severity` / `.Created` 非空；
- `.Severity` 属于 `OK` / `Warning` / `Critical`。

**注意**：如果机器上没产生过事件，`Members` 会是**空数组**，这也是通过（断言用 `>= 0`，不要写死 `>= 1`）。

**额外可用动作**（同资源上的标准 Redfish 动作，可顺手验一下路由存在）

```bash
S -X POST -H 'Content-Type: application/json' -d '{}' \
  "$BASE/redfish/v1/Systems/system/LogServices/EventLog/Actions/LogService.ClearLog/"
# 期望 200 或 204（清空事件日志）—— 属破坏性，按需执行
```

---

## 行43 — Logs Dump（⚠️ 本 build 未启用，404 是预期）

**测试逻辑**
`redfish.cpp:154` 是 `if constexpr (BMCWEB_REDFISH_DUMP_LOG) { requestRoutesDumpLogService(app); }`。
本 build `BMCWEB_REDFISH_DUMP_LOG=false`，**这整块路由在编译期就被删掉了**，所以访问会得到一个**不带 `resourceNotFound` 错误体的空 404**。

同理，Systems / Managers 的 `LogServices` 集合里也**不会出现 `Dump` 这个成员**
（`log_services.hpp:916-922` 是 `if constexpr (BMCWEB_REDFISH_DUMP_LOG)` 包着的）。

这两者的区别很重要：

| 现象 | 含义 |
|---|---|
| `404` + `{"error":{"code":"Base.1.19.ResourceMissingAtURI"}}` | 路由**存在**，只是资源没找到 |
| `404` + 空 body（或纯 HTML） | 路由**根本没注册** ← 本 build 就是这种 |

**测试方法**

```bash
S "$BASE/redfish/v1/Managers/bmc/LogServices/Dump/"; echo
S "$BASE/redfish/v1/Systems/system/LogServices/Dump/"; echo
```

**例子（期望结果）**：两个都是 `404`，且 `/tmp/last_body` 几乎为空。

**判定与后续**

```bash
# 用"有没有错误体"来区分两种 404
curl -sk "${AUTH[@]}" "$BASE/redfish/v1/Managers/bmc/LogServices/Dump/" | jq -r '.error.code // "路由未注册"'
# 输出 "路由未注册" → 确认编译期关闭
```

若业务**确实需要** Dump，在 bmcweb 的 bbappend 里加：

```bitbake
PACKAGECONFIG:append = " dump-log"
# 或 EXTRA_OEMESON += "-Dredfish-dump-log=enabled"
```

重编部署后再测 `.../Dump/Entries/`，此时才应该返回 `200`。

---

# 七、AccountService（业务行 42）

## 行42 — 创建用户

**测试逻辑**
验证用户 CRUD 的**完整闭环**：`POST` → `201` → 回读 → `DELETE` → `204`。
必须检查的几点：
1. 响应是 `201`（不是 `200`），且带 `Location`；
2. 回读时 **`Password` 字段必须是 `null`**（bmcweb 永远不回显密码）；
3. `RoleId` 回读一致；
4. 删除后确实消失。

**请求体白名单（`account_service.hpp:1922-1929`）**

| 键 | 类型 | 必填？ |
|---|---|---|
| `UserName` | string | ✅ **必填** |
| `Password` | string | ✅ **必填** |
| `RoleId` | string | ⚠️ **实际上必填**，见下 |
| `Enabled` | bool | ❌ 可选，默认 `true` |
| `AccountTypes` | string[] | ❌ 可选 |

`UserName` / `Password` 在代码里是**非 optional 的 `std::string`**，缺失直接 400。

**`RoleId` 的坑：只有三个合法值，而且默认值是错的**
`account_service.hpp:1935` 是 `roleIdJson.value_or("User")`，而
`getPrivilegeFromRoleId()`（`:108-123`）**只认这三个**：

| RoleId | 映射到的 D-Bus 权限 |
|---|---|
| `Administrator` | `priv-admin` |
| `Operator` | `priv-operator` |
| `ReadOnly` | `priv-user` |

**没有 `NoAccess`**（新版本 DMTF 才引入，这个 SRCREV 还不支持）。
所以**省略 `RoleId` 会拿到 400 `propertyValueNotInList`，list 里显示 `"User"`** ——
这就是"默认值 `User` 不在合法集合里"造成的。**POST 时务必显式带 `RoleId`**。

**测试方法**

```bash
# 注意：不要用 `U` 当用户名 —— `U` 在前面以太网章节已经被占用为以太网 URI。
ACCT="biztest01"

# 创建（POST —— 用 C，不要用 P！成功会打印 Location 头）
C "/redfish/v1/AccountService/Accounts/" \
  "{\"UserName\":\"$ACCT\",\"Password\":\"0penBmc!23\",\"RoleId\":\"ReadOnly\",\"Enabled\":true}"
# 期望 201 + Location: /redfish/v1/AccountService/Accounts/biztest01

# 回读
G "/redfish/v1/AccountService/Accounts/$ACCT/" | jq .

# 清理
D  "/redfish/v1/AccountService/Accounts/$ACCT/"; echo   # 期望 204
SP "/redfish/v1/AccountService/Accounts/$ACCT/"; echo   # 期望 404
```

**例子（期望响应）**

创建：`HTTP 201` + `Location: /redfish/v1/AccountService/Accounts/biztest01`

回读：

```json
{
  "@odata.id": "/redfish/v1/AccountService/Accounts/biztest01",
  "@odata.type": "#ManagerAccount.v1_13_0.ManagerAccount",
  "Id": "biztest01",
  "UserName": "biztest01",
  "RoleId": "ReadOnly",
  "Enabled": true,
  "Locked": false,
  "Password": null
}
```

**判据**

```bash
G "/redfish/v1/AccountService/Accounts/$ACCT/" > /tmp/acct.json
jq -e '.UserName == "biztest01"'  /tmp/acct.json
jq -e '.RoleId   == "ReadOnly"'   /tmp/acct.json
jq -e '.Enabled  == true'         /tmp/acct.json
jq -e '.Password == null'         /tmp/acct.json   # 密码绝不回显
```

**负向用例**

> ⚠️ 这里是**创建用户**，所以用 `C`（POST）。用 `P`（PATCH）打集合只会得到 **`405`** ——
> `/redfish/v1/AccountService/Accounts/` 未注册 PATCH（`account_service.hpp:2342-2354`）。

```bash
# ① 非法 RoleId → 400 propertyValueNotInList
C "/redfish/v1/AccountService/Accounts/" \
  '{"UserName":"tmpbad","Password":"0penBmc!23","RoleId":"NoAccess"}'

# ② 缺 RoleId → 400 propertyValueNotInList（list 里是 "User"，就是这个默认值坑）
C "/redfish/v1/AccountService/Accounts/" \
  '{"UserName":"tmpbad","Password":"0penBmc!23"}'

# ③ 多余键 → 400 propertyUnknown
C "/redfish/v1/AccountService/Accounts/" \
  '{"UserName":"tmpbad","Password":"0penBmc!23","RoleId":"ReadOnly","Email":"a@b.c"}'

# 三个用例都应仍在 400 —— 若拿到 405，说明你误用了 P
```

**常见失败**
- `400 propertyValueNotInList` 指向 `RoleId` → 值不在 {`Administrator`,`Operator`,`ReadOnly`}，或**根本没传**（见上）；
- `400` → `Password` 不符合复杂度要求（一般要求 ≥ 8 位且含大小写/数字）；
- 重复创建同名用户 → `400 propertyValueError`（UserName 已存在）；
- 想确认可用角色列表：`G /redfish/v1/AccountService/Roles/ | jq -r '.Members[]["@odata.id"]'`。

---

# 八、以太网口 VLAN（业务行 44）

## 行44 — 创建 VLAN 子接口

**测试逻辑**
VLAN 是**在集合上 POST**（不是在成员上 PATCH）来创建一个**新的子接口**。
`ethernet.hpp:2187-2191` 的 `readJsonPatch` 白名单只有三个键，**少一个就 400**：

| 键 | 含义 |
|---|---|
| `Links/RelatedInterfaces` | **数组，长度必须恰好为 1**，元素是父接口的完整 `@odata.id` |
| `VLAN/VLANEnable` | 必须是 `true` —— **`false` 会被明确拒绝**（`ethernet.hpp:2240-2245`）；**省略该键同样会被拒**（`!vlanEnable` 对 `nullopt` 也为真） |
| `VLAN/VLANId` | 1–4094 |

`Links/RelatedInterfaces[0].@odata.id` 必须能被解析成
`/redfish/v1/Managers/**bmc**/EthernetInterfaces/<父接口名>`（`readUrlSegments` 里 `bmc` 是**字面量**，写别的 manager id 会 `400 propertyValueNotInList`）。

创建成功后新接口名字是 **`<父接口>_<VLANId>`**（如 `eth0_42`），可以直接 GET 到。

**测试方法**

```bash
ETH=eth0; VID=142; VIF="${ETH}_${VID}"

# 创建（POST → 用 C）
C "/redfish/v1/Managers/bmc/EthernetInterfaces/" "{
    \"VLAN\":{\"VLANEnable\":true,\"VLANId\":$VID},
    \"Links\":{\"RelatedInterfaces\":[
        {\"@odata.id\":\"/redfish/v1/Managers/bmc/EthernetInterfaces/$ETH\"}]}}"
# 期望 201 + Location: /redfish/v1/Managers/bmc/EthernetInterfaces/eth0_142

# 回读新接口
G "/redfish/v1/Managers/bmc/EthernetInterfaces/$VIF/" | jq '{Id, VLAN}'

# 清理
D "/redfish/v1/Managers/bmc/EthernetInterfaces/$VIF/"; echo   # 期望 204
```

**例子（期望响应）**

创建：`HTTP 201`；`Location: /redfish/v1/Managers/bmc/EthernetInterfaces/eth0_142`

回读：

```json
{
  "@odata.id": "/redfish/v1/Managers/bmc/EthernetInterfaces/eth0_142",
  "@odata.type": "#EthernetInterface.v1_12_0.EthernetInterface",
  "Id": "eth0_142",
  "Name": "eth0_142",
  "VLAN": { "VLANEnable": true, "VLANId": 142, "Tagged": true },
  "Links": {
    "RelatedInterfaces": [
      { "@odata.id": "/redfish/v1/Managers/bmc/EthernetInterfaces/eth0" }
    ]
  }
}
```

**负向用例（必做）**

```bash
# ① VLANEnable=false → 必须 400 propertyValueIncorrect
C "/redfish/v1/Managers/bmc/EthernetInterfaces/" "{
    \"VLAN\":{\"VLANEnable\":false,\"VLANId\":$VID},
    \"Links\":{\"RelatedInterfaces\":[
        {\"@odata.id\":\"/redfish/v1/Managers/bmc/EthernetInterfaces/$ETH\"}]}}"

# ② RelatedInterfaces 给 2 个元素 → 必须 400 arraySizeTooLong
C "/redfish/v1/Managers/bmc/EthernetInterfaces/" "{
    \"VLAN\":{\"VLANEnable\":true,\"VLANId\":$VID},
    \"Links\":{\"RelatedInterfaces\":[
        {\"@odata.id\":\"/redfish/v1/Managers/bmc/EthernetInterfaces/$ETH\"},
        {\"@odata.id\":\"/redfish/v1/Managers/bmc/EthernetInterfaces/$ETH\"}]}}"

# ③ 完全省略 VLANEnable → 同样被拒（!vlanEnable 对 nullopt 也为真）
C "/redfish/v1/Managers/bmc/EthernetInterfaces/" "{
    \"VLAN\":{\"VLANId\":$VID},
    \"Links\":{\"RelatedInterfaces\":[
        {\"@odata.id\":\"/redfish/v1/Managers/bmc/EthernetInterfaces/$ETH\"}]}}"

# ① ② ③ 都应仍在 400（C 会把响应体打印出来，直接看 .error.code）
```

**判据**
- 正常创建 → `201` + `Location`，回读 `.VLAN.VLANId` 一致、`.VLAN.VLANEnable == true`；
- `VLANEnable=false` → `400 propertyValueIncorrect`（**这个是 ✅，证明校验生效**）；
- `RelatedInterfaces` 长度 ≠ 1 → `400 arraySizeTooLong`；
- `DELETE` → `204`。

**常见失败**
- `400 propertyValueNotInList` 指向 `Links/RelatedInterfaces/0/@odata.id` → 父接口 URI 不是 `/redfish/v1/Managers/bmc/EthernetInterfaces/<name>` 这个精确格式（注意必须是 `bmc`，不能是别的 manager id）。

---

# 九、UpdateService 固件（业务行 45 / 46 / 47）

## 行45 — 固件清单

**测试逻辑**
`UpdateService` 是个**导航资源**（不是集合），它通过 `FirmwareInventory` 指向真正的清单集合。要验证三层：
1. `GET /redfish/v1/UpdateService/` 能拿到 `.FirmwareInventory["@odata.id"]`；
2. 顺着这个 URI 能列出所有固件条目；
3. **顺带验证 §0.2 的编译配置是活的** —— `MaxImageSizeBytes` = `BMCWEB_HTTP_BODY_LIMIT * 1024 * 1024`
   （`update_service.hpp:1214-1215`），本 build 应恰好等于 `31457280`（30 MiB）。
   这是一条**自证式检查**：能对上就说明 `bmcweb_config.h` 里读到的宏确实是运行时的宏。

本 build `BMCWEB_REDFISH_UPDATESERVICE_USE_DBUS=true`，清单**来自 D-Bus**
（`xyz.openbmc_project.Software.Version`），所以条目名一般是 `bmc_active` 这类。

**测试方法**

```bash
G /redfish/v1/UpdateService/ | jq '{
  FirmwareInventory, MultipartHttpPushUri, ServiceEnabled,
  MaxImageSizeBytes, HttpPushUriOptions, Actions
}'
G /redfish/v1/UpdateService/FirmwareInventory/ | jq .
```

**例子（期望响应）——`GET /redfish/v1/UpdateService/`**

```json
{
  "@odata.id": "/redfish/v1/UpdateService",
  "@odata.type": "#UpdateService.v1_11_1.UpdateService",
  "Id": "UpdateService",
  "Name": "Update Service",
  "ServiceEnabled": true,
  "HttpPushUri": "/redfish/v1/UpdateService/update",
  "MultipartHttpPushUri": "/redfish/v1/UpdateService/update-multipart",
  "MaxImageSizeBytes": 31457280,
  "HttpPushUriOptions": {
    "HttpPushUriApplyTime": { "ApplyTime": "Immediate" }
  },
  "FirmwareInventory": { "@odata.id": "/redfish/v1/UpdateService/FirmwareInventory" },
  "Actions": null
}
```

> ⚠️ **`"Actions": null` 是预期结果，不是错误！**
> `SimpleUpdate` 的 `Actions` 块和它的路由**写在同一个 `if constexpr (BMCWEB_REDFISH_ALLOW_SIMPLE_UPDATE)` 里**
> （`update_service.hpp:1216-1229`），本 build 该宏为 `false`，所以
> **`Actions` 整个键都不会被填**。这正好是行47 A5「SimpleUpdate 未编译」的读取侧证据。

**例子（期望响应）——`GET /redfish/v1/UpdateService/FirmwareInventory/`**

```json
{
  "@odata.id": "/redfish/v1/UpdateService/FirmwareInventory",
  "@odata.type": "#SoftwareInventoryCollection.SoftwareInventoryCollection",
  "Name": "Software Inventory Collection",
  "Members@odata.count": 2,
  "Members": [
    { "@odata.id": "/redfish/v1/UpdateService/FirmwareInventory/bmc_active" },
    { "@odata.id": "/redfish/v1/UpdateService/FirmwareInventory/bmc_backup" }
  ]
}
```

**判据**

```bash
G /redfish/v1/UpdateService/ > /tmp/us.json
jq -e '.MaxImageSizeBytes == 31457280' /tmp/us.json         # 自证编译宏
jq -e '.FirmwareInventory."@odata.id"' /tmp/us.json
jq -e '.MultipartHttpPushUri == "/redfish/v1/UpdateService/update-multipart"' /tmp/us.json
jq -e '.Actions == null'            /tmp/us.json            # SimpleUpdate 未编译

G /redfish/v1/UpdateService/FirmwareInventory/ > /tmp/fwc.json
jq -e '.Members|type=="array"'             /tmp/fwc.json
jq -e '."Members@odata.count" >= 1'        /tmp/fwc.json
```

**常见失败**
- `Members` 为空 → D-Bus 上没有 `Software.Version` 对象，检查 `ssh root@$BMC 'busctl tree xyz.openbmc_project.Software'`。
- `.MaxImageSizeBytes` 不是 `31457280` → 你的 `bmcweb_config.h` 与手册 §0.2 不一致，请重新确认 bbappend 里的 `-Dhttp-body-limit=`。

---

## 行46 — 固件详情

**测试逻辑**
验证单条固件条目的关键字段：
- `Version` —— 版本号（业务最关心）；
- `Name` —— 条目名；
- `Updateable` —— **是否可升级**（只读，由 bmcweb 判断）；
- `Status.State` —— 资源状态。

**测试方法**

```bash
FW=$(G /redfish/v1/UpdateService/FirmwareInventory/ | jq -r '.Members[0]["@odata.id"]')
G "$FW" | jq .
```

**例子（期望响应）**

```json
{
  "@odata.id": "/redfish/v1/UpdateService/FirmwareInventory/bmc_active",
  "@odata.type": "#SoftwareInventory.v1_1_0.SoftwareInventory",
  "Id": "bmc_active",
  "Name": "Software Inventory",
  "Version": "2.15.0-dev-1234-gabcdef",
  "Updateable": false,
  "Status": { "HealthRollup": "OK" }
}
```

> **注意字段形态**（`update_service.hpp:1404-1411`）：
> `@odata.type` 是 **`v1_1_0`**（不是最新的 v1_x_y）；
> `Name` 是**固定字面量 `"Software Inventory"`**（不是"BMC Firmware"）；
> `Updateable` 先被写死为 `false`，随后由 `sw_util::getSwUpdatableStatus()` 按 D-Bus 状态覆盖；
> 状态用的是 **`Status.HealthRollup`（字符串）**，**没有 `Status.State`**。

**判据**

```bash
G "$FW" > /tmp/fw.json
jq -e 'has("Version")'                 /tmp/fw.json   # 版本（业务最关心）
jq -e 'has("Id")'                      /tmp/fw.json
jq -e '.Updateable|type=="boolean"'    /tmp/fw.json
jq -e '.Status.HealthRollup|type=="string"' /tmp/fw.json
jq -e '."@odata.type" == "#SoftwareInventory.v1_1_0.SoftwareInventory"' /tmp/fw.json
```

**交叉验证**

```bash
ssh root@$BMC 'busctl get-property xyz.openbmc_project.Software.BMC.Updater \
  /xyz/openbmc_project/software/active \
  xyz.openbmc_project.Software.Version Version Purpose'
# Redfish 的 .Version 应与这里的 Version 一致；
# Purpose 形如 "xyz.openbmc_project.Software.Version.VersionPurpose.BMC"，
# bmcweb 会把最后一段截出来用。
```

---

## 行47 — 升级固件（⚠️ 破坏性）

**测试逻辑**
三条更新入口的**请求格式完全不同**，先看清再动手（`update_service.hpp:1445-1469`）：

| URL | Handler | 要求的 `Content-Type` | 请求体 |
|---|---|---|---|
| `/redfish/v1/UpdateService/update/` | `handleUpdateServicePost` (`:1129`) | **`application/octet-stream`**（`bmcweb::asciiIEquals`，`:` 后面有空格算不同值） | 固件镜像的**原始字节流**（不是 JSON！） |
| `/redfish/v1/UpdateService/update-multipart/` | `handleUpdateServiceMultipartUpdatePost` (`:1153`) | `multipart/form-data`（`contentType.starts_with("multipart/form-data")`） | 两个表单域：`UpdateParameters`(JSON) + `UpdateFile`(二进制) |
| `.../Actions/UpdateService.SimpleUpdate/` | —— | —— | ⚠️ **本 build 未注册**：`BMCWEB_ROUTE` 整体包在 `if constexpr (BMCWEB_REDFISH_ALLOW_SIMPLE_UPDATE)` 里（`update_service.hpp:1436-1444`），本 build 该宏为 `false` → **404** |

**两个门禁返回的状态码不一样**，这是最容易误判的地方：

- `update/`（`:1142-1150`）：Content-Type 不是 `application/octet-stream` → **`400`**，
  且走的是裸 `bad_request`，**响应体是空的**（没有任何 `error.code`）。
  ⚠️ 注意用的是 `bmcweb::asciiIEquals(contentType, "application/octet-stream")` **全等比较**，
  所以带 `; charset=utf-8` 后缀也会被判为不合法。
- `update-multipart/`（`:1164-1186`）：Content-Type 不以 `multipart/form-data` 开头 → **`415`**
  `unsupported_media_type`。

所以负向断言要按"Content-Type 门禁"来理解，而不是"缺 JSON 字段"。

**阶段 A（安全，必做）—— 证明端点活着 + 校验分支生效**

```bash
# A1. 用 JSON 打 update/ → 期望 400（被 Content-Type 门禁拦下，无 body）
S -X POST -H 'Content-Type: application/json' -d '{}' \
  "$BASE/redfish/v1/UpdateService/update/"; echo
cat /tmp/last_body | jq -c '.error.code // "无错误体（门禁拦截）"'

# A2. 用正确的 Content-Type 但空 body → 期望 400（镜像内容无效）
S -X POST -H 'Content-Type: application/octet-stream' --data-binary '' \
  "$BASE/redfish/v1/UpdateService/update/"; echo

# A3. multipart 端点：Content-Type 不对 → 期望 415
S -X POST -H 'Content-Type: application/json' -d '{}' \
  "$BASE/redfish/v1/UpdateService/update-multipart/"; echo

# A4. multipart 端点：格式对但缺 UpdateFile → 期望 400 propertyMissing
S -X POST "$BASE/redfish/v1/UpdateService/update-multipart/" \
  -F 'UpdateParameters={"Targets":["/redfish/v1/UpdateService/FirmwareInventory/bmc_active"]};type=application/json'; echo
cat /tmp/last_body | jq -r '.error.code'

# A5. SimpleUpdate 路由存在性检查 → 期望 404（本 build 未编译该分支）
S "$BASE/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate/"; echo

# A6. 读取侧证据：/UpdateService/ 里根本没有 Actions 键
G /redfish/v1/UpdateService/ | jq -c '{Actions, has_actions: has("Actions")}'
```

**期望结果（阶段 A）**

| 用例 | 期望 | 说明 |
|---|---|---|
| A1 | `400` + **无错误体** | Content-Type 门禁（`:1142-1150`） |
| A2 | `400` | 空镜像内容解析失败 |
| A3 | **`415`** | multipart Content-Type 门禁（`:1164-1186`，`unsupported_media_type`） |
| A4 | `400` + `propertyMissing` | `update_service.hpp:845` 报 `"UpdateFile"` 缺失 |
| A5 | `404` | `BMCWEB_REDFISH_ALLOW_SIMPLE_UPDATE=false`，路由未注册 |
| A6 | `{"Actions":null,"has_actions":false}` | SimpleUpdate 的 `Actions` 块同受该宏控制（`:1216-1229`） |

**能拿到 A1–A6 的预期状态码，就足以证明"接口已实现且参数校验在工作"** ——
这正是手动测试这一步的目的，不需要真的刷固件。

> 若业务需要 `SimpleUpdate`（用 `ImageURI` + `TransferProtocol` 让 BMC 自己去 HTTP 服务器拉镜像），
> 需在 bbappend 里打开 `-Dredfish-allow-simple-update=true` 后重编。

**阶段 B（真刷固件，需明确授权）**

```bash
# 前置：备份 BMC 配置；确认镜像与板子型号匹配；接好串口；
#       确认 ApplyTime 已设为 Immediate（否则重启才生效）
#   P /redfish/v1/Managers/bmc/NetworkProtocol ... 不需要；
#   ApplyTime 一般在 /redfish/v1/UpdateService/ 的 HttpPushUriOptions 附近配置

curl -sk "${AUTH[@]}" -D /tmp/hdr -o /tmp/body -w 'HTTP %{http_code}\n' \
  -X POST "$BASE/redfish/v1/UpdateService/update-multipart/" \
  -F 'UpdateParameters={"Targets":["/redfish/v1/UpdateService/FirmwareInventory/bmc_active"],"@Redfish.OperationApplyTime":"Immediate"};type=application/json' \
  -F "UpdateFile=@/path/to/obmc-phosphor-image-evb-ast2600.static.mtd.tar;type=application/octet-stream"

cat /tmp/body
TASK=$(jq -r '."@odata.id" // .Id' /tmp/body)
G "$TASK" | jq '{state:.TaskState, pct:.PercentComplete}'
```

> `UpdateParameters` 里只认两个键（`update_service.hpp:763-770`）：
> `Targets`（数组，元素必须是 `.../FirmwareInventory/<id>` 或 `/redfish/v1/Managers/bmc`）
> 和 `@Redfish.OperationApplyTime`（可选，取值 `Immediate` / `OnReset`，见 `:651-669`）。**多写键会 400。**

**例子（阶段 B 期望响应）**

```json
{
  "@odata.id": "/redfish/v1/TaskService/Tasks/1",
  "@odata.type": "#Task.v1_7_0.Task",
  "Id": "1",
  "Name": "Task 1",
  "TaskState": "Running",
  "PercentComplete": 0,
  "TaskStatus": "OK"
}
```

**判据**
- 阶段 A：A1–A6 全部返回预期状态码（`400`/`415`/`404`，如阶段 A 表）；
- 阶段 B：成功时返回 `200`/`202` + 可轮询的 Task；轮询到 `TaskState == "Completed"` 后，BMC 会**自动重启**，重连后 `.Version` 应变成新版本。

**风险提示**
- 刷错镜像会变砖，只能走 JTAG/串口恢复；
- 升级过程中**不要断电**；
- 刷完后 `curl` 会断线，需要等 3–5 分钟再重连；
- 若 `ApplyTime=OnReset`，固件写入后**要等重启才生效**，此时 `.Version` 还不会变，属正常。

---

# 十、汇总对照表

| 业务行 | 接口 | 方法 | 关键断言 | 风险 |
|---|---|---|---|---|
| 5 | 传感器列表 | GET | `Members` 全部含 `_` | 无 |
| 6 | 全部读数 | `$expand`（预期 **501**） 或 逐个 GET | 每个 200，行数与 count 一致 | 无 |
| 7 | 单个传感器 | GET | `has("Reading")` + `Status.State` 合法 | 无 |
| 13 | 订阅列表 | GET | `Members` 是数组 | 无 |
| 38 | 创建订阅 | POST | `201` + Location；`Protocol` 只能 `"Redfish"` | 低（对端收心跳） |
| 15 | 删除订阅 | DELETE | `204` 后 GET `404` | 低 |
| 17 | HostName 读 | GET | `type=="string"` | 无 |
| 22–25 | IPv4 读 | GET | 掩码正则 / Gateway 是字符串 | 无 |
| 27 | DHCPv4 | GET | `OperatingMode` ∈ {Enabled,Disabled} | 无 |
| 28–32 | IPv6/DHCPv6 | GET | `PrefixLength` 是 number | 无 |
| 33 | HostName 写 | PATCH | `204` + 回读一致 + 还原 | 中（改主机名） |
| 34 | FQDN 写 | PATCH | `204`；**HostName 会被同步改**；无点 → 400 | 中 |
| 35 | 静态 IP | PATCH（**只做负向**） | 非法掩码 → 400 | **高（断网）** |
| 36 | 静态 DNS | PATCH | `204` + 还原 | 低 |
| 37 | NTP | PATCH | `NTP.NTPServers` / `NTP.ProtocolEnabled` 均可写；写 `NTPEnable` → 400 | 中（关 NTP 影响对时） |
| 20 | Journal | GET | `@odata.type` + `EntryType=="Event"` | 无 |
| 21 | EventLog | GET | `Message`/`Severity`/`Created` | 无 |
| 43 | Dump | GET | **本 build 404 是预期** | 无 |
| 42 | 创建用户 | POST | `201`；回读 `Password==null` | 低（记得删） |
| 44 | VLAN | POST | `201`；`VLANEnable=false` → 400 | 中（新增接口） |
| 45 | 固件清单 | GET | `count>=1` | 无 |
| 46 | 固件详情 | GET | `Version` 非空；状态看 `Status.HealthRollup` | 无 |
| 47 | 固件升级 | POST | `update/` 需 `octet-stream`，JSON → **400（无 body）**；multipart JSON → **415**，缺 `UpdateFile` → **400**；`SimpleUpdate` → **404**（未编译），`/UpdateService/` 无 `Actions` 键 | **极高（变砖）** |

---

# 十一、明确不在本手册内的 28 条

🟡3 + 🟠7 + 🔴18 共 **28 条**（`CoolingUnit` / `SetMode` / `Coolant` / `CoolingLoop` /
`ThermalEquipment` 整个子树，以及各 OEM `cpt` / `TSMC` 片段）**当前应返回 400 或 404，
这是预期行为，不是缺陷**。它们的差异原因见业务 API 映射表。

等 OEM 片段按实施指南补齐后，再把这些条目追加到本手册与 `biz_api_check.sh` 即可。

---

# 附：配套脚本

本手册配两个文件，都在 `meta-cdu/scripts/`：

| 文件 | 定位 | 怎么用 |
|---|---|---|
| `biz_env.sh` | **交互式环境** —— 登录 + `G`/`S`/`P`/`C`/`D`/`SP` 函数 + 自动探测运行时 ID | `source meta-cdu/scripts/biz_env.sh`（**必须 source，不能直接执行**） |
| `biz_api_check.sh` | **一键回归** —— 本手册 30 条接口的自动化等价实现 | 直接执行（见下） |

**手动逐条测试**用前者（配合本手册）；**快速回归**用后者。

```bash
cd meta-cdu/scripts
BMC=192.168.1.100 RUN_DESTRUCTIVE=0 ./biz_api_check.sh   # 只跑只读用例（最安全）
BMC=192.168.1.100 ./biz_api_check.sh                     # 全量（写操作自动还原）
BMC=192.168.1.100 RUN_FIRMWARE_UPDATE=1 FW_IMAGE=/tmp/xxx.static.mtd.tar ./biz_api_check.sh
```
