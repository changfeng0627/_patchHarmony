# 联想 Y70 新一代：Droidspaces 内核主模块

本仓库仅维护用户这台联想 Y70 新一代（系统报告型号 `Motorola XT2611-1`）的已核对内核：

```text
6.12.58-android16-6-gb0a9599c6c01-ab14987696-4k
```

架构为 AArch64、4K 页，Root 为 APatch 分支 FolkPatch。其他型号、内核更新或其他 Root 环境均未验证。保留的源码、依赖和检查工具均服务于此主模块；不再提供其他设备兼容模块、实验模块或其他内核的构建入口。

## 下载和使用

[下载 Y70 发布版](https://github.com/changfeng0627/_patchHarmony/releases/tag/y70-6.12.58-ab14987696-20261018)。选择 `droid_lkm-Y70-6.12.58-ab14987696-only.zip`，或者单独下载 `droid_lkm.ko` 和 `load_droid_lkm.sh`。

把 `load_droid_lkm.sh` 与 `droid_lkm.ko` 放在手机同一个文件夹，在 ZeroTermux 中进入该文件夹运行：

```sh
sh ./load_droid_lkm.sh
```

脚本会申请 Root，核对型号、完整内核版本和模块 SHA256，并以 `gate=1` 加载主模块。支持移动文件夹、绝对或相对路径，以及中文、空格、单引号等路径。已加载且参数正确时跳过，不卸载或重复加载。共享存储通常不可直接执行脚本，因此需要 `sh`。

只检查文件与私有副本，不加载：

```sh
sh ./load_droid_lkm.sh --check
```

不刷机，不放宽 SELinux，不设开机自启。手机重启后需重新运行；系统更新后若内核不同则拒绝加载。该脚本的哈希固定为下面已实机验收的发布模块，不可直接搭配任意重建产物。

## 验收范围

发布模块 SHA256：

```text
7ccdc3283c8532f5f28b7422f87db6030de53a79f4682b7d3560ea9528157f74
```

这份二进制来自原构建提交 `40dd97881d673be44555409c6013892174eead89`，正常 modpost 生成版本记录，无 CRC/签名绕过。已验证 ELF/vermagic、196 个导入符号 CRC、结构布局、临时加载、IPC/PID 功能，以及用户原 Ubuntu 24.04.5 容器的 XFCE 显示和终端输入。桌面验收另有容器用户态兼容调整，不能认为只加载模块就会自动完成桌面安装。

SELinux 保持 Enforcing。桌面使用已验证的软件 llvmpipe；GPU 硬件加速、实际音频播放、Docker、用户命名空间、多容器隔离和长时间稳定性没有通过本次完整验收。模块仍是限定设备/内核的预发布版本。

## 构建

构建输入固定为 AOSP 内核提交 `b0a9599c6c01ec540e2252ca3a0e87b5b8c47c97`、官方构建 `14987696` 的配置/符号表/vmlinux 和 Clang 19.0.1 r536225。输入哈希见 `scripts/y70-reference.json`，依赖由 `.sdk-version` 与 `deps.lst` 固定。

GitHub Actions 的 `.github/workflows/build.yml` 仅构建 `droid_lkm.ko` 和用户态 `droidspaces-check`，并检查符号 CRC、命名空间、ELF 和构建警告。构建容器只提供工具链，使用目标未修改内核的 modpost。私有上游依赖需要仓库现有 `KMSDK_TOKEN`。

在相同容器和依赖环境中：

```sh
scripts/fetch-deps.sh
bash scripts/build-y70.sh
python3 scripts/verify-y70.py --modules out/y70 --reference .target/reference --output out/y70/report/verification.json
```

产物在 `out/y70/`。CI 静态通过不等于重建二进制已在手机加载；新的文件哈希必须重新核对并验收，才应修改加载脚本中的固定哈希。仓库清理不改变上面已验收发布模块的二进制。

## 来源与许可

GPL-2.0，保留原 LICENSE 和源码版权声明。

- [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS)
- [原项目](https://github.com/Dere3046/_patchHarmony)
- [KMSDK](https://github.com/Dere3046/KMSDK)
- [KallRecon](https://github.com/Dere3046/KallRecon)、[Type_info](https://github.com/Dere3046/Type_info)、[KernCall](https://github.com/Dere3046/KernCall)、[HooKern](https://github.com/Dere3046/HooKern)
