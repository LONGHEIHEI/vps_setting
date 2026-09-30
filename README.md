# VPS Setting

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/LONGHEIHEI/vps_setting/main/bootstrap.sh)
```

## 本地运行

```bash
bash vps_init_suite.sh
```

## 运行测试

在项目根目录执行以下命令，运行 Shell 语法检查和无需 root 权限的纯函数测试：

```bash
bash tests/run.sh
```

## 支持范围

- 目标环境：Linux VPS；包管理器需为 `apt`、`dnf` 或 `yum` 系列，建议使用 systemd。
- 权限：系统配置、软件安装、服务管理和防火墙操作通常需要 root 权限。
- Shell：Bash。脚本依赖的具体系统命令会随菜单功能变化；未安装的可选组件可能导致对应功能不可用。
- 发行版版本：项目尚未维护逐版本验证矩阵；运行前应在目标系统测试，不能据此视为所有版本均已验证。
- 影响范围：功能会修改系统配置、账户、网络规则、服务和软件；卸载与 DD 会造成数据删除或系统不可用。DD 不属于常规初始化操作。

## 在线启动校验

在线启动会从 GitHub 下载源码压缩包并执行。默认分支 `main` 会变化，生产主机应固定提交号或标签，并提供该归档的 SHA-256：

```bash
VPS_SETTING_REF='<提交号或标签>' VPS_SETTING_SHA256='<归档的64位SHA-256>' bash <(curl -fsSL https://raw.githubusercontent.com/LONGHEIHEI/vps_setting/main/bootstrap.sh)
```

未提供 `VPS_SETTING_SHA256` 时启动器会警告，但仍会继续；不要将未校验的远程脚本用于重要主机。下载的外部安装脚本只做基础文件与 Bash 语法检查，该检查不能证明脚本可信。

## 日志与故障处理

工具目前以终端输出操作结果，不维护统一的持久化日志。执行失败时记录终端错误信息及退出码；建议在维护窗口从终端运行并保存输出。涉及配置变更的操作应先自行备份，并保留当前 SSH 会话直至确认新连接可用。

## 项目结构

`lib/` 按界面、系统基础、SSH、防火墙、网络、服务等职责划分；Fail2Ban 已从 SSH 模块拆分至 `lib/18_fail2ban.sh`。公共函数仍由 `main.sh` 按顺序加载，新增模块需同步登记加载顺序。
