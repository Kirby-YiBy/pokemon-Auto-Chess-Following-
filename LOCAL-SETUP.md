# 本地定制说明（LOCAL-SETUP）

这个仓库是从上游克隆后**加了本地改动**的版本。本文件记录改了什么、为什么改、以及怎么跟上上游更新。
**这是本地文件，从未推送，上游没有它。**

---

## 一、本地改了什么

只有一个主题：**让游戏可以在完全离线的情况下运行**。

上游的登录必须连 Google（Firebase），断网就进不去。下面这 5 个文件让客户端和服务端都改用**本地的 Firebase Auth 模拟器**（`localhost:9099`），并且这个行为由 `.env` 里的一个变量控制，**留空就退回原来的联网模式**。

| 文件 | 改动 | 为什么 |
|---|---|---|
| `app/config/server/firebase.ts` | 新增导出 `AUTH_EMULATOR_HOST` | 把 `.env` 的变量暴露给客户端（沿用原有 `FIREBASE_CONFIG` 的写法） |
| `esbuild.js` | `define` 里加一条 | esbuild 在**构建时**替换 `process.env.*`，不加这条浏览器里会报 `process is not defined` |
| `app/public/src/network.ts` | 新增 `ensureFirebase()` | **关键**：客户端有三处各自 `initializeApp`，但模拟器配置必须**在任何认证发生之前**生效，否则 SDK 会一边登录模拟器、一边去连真 Google（表现为 `accounts:lookup` 返回 400，然后进房间被 4104 踢掉） |
| `app/public/src/pages/component/auth/login.tsx` | 加 `emulatorConfig` | FirebaseUI **用自己的临时 app 实例**登录，只认配置对象上的 `emulatorConfig`，对 `firebase.auth().useEmulator()` 无效 |
| `app/public/src/pages/replay.tsx` | 改用 `ensureFirebase()` | 它原本也自己 `initializeApp`，冷启动进 `/replay` 会绕过登录流程 |
| `app/app.config.ts` | CSP 白名单加模拟器地址 | 模拟器是不同端口＝不同 origin，`'self'` 不覆盖；不加会被浏览器拦掉。只在启用模拟器时才放宽 |

另外两个配套文件（非上游）：

| 文件 | 作用 |
|---|---|
| `start-offline.cmd` | 一键启动 MongoDB + Auth 模拟器 + 游戏。**必须留在仓库根目录**，它靠 `%~dp0` 定位自己 |
| `LOCAL-SETUP.md` | 本文件 |

## 二、外部依赖（不在仓库里）

离线模式依赖仓库外的这几个东西，都在 `E:\mongodb\`：

```
E:\mongodb\data\                               MongoDB 数据（含 726 个 bot）
E:\mongodb\mongodb-win32-x86_64-windows-8.0.4\ mongod 程序
E:\mongodb\firebase-emulator\                  Firebase Auth 模拟器 + 账号持久化
E:\mongodb\toggle-admin.cmd                    双击切换账号角色（ADMIN/BASIC）
```

## 三、怎么启动

双击仓库根目录的 **`start-offline.cmd`**，会开三个窗口：`mongo (27017)`、`firebase-auth (9099)`、`pokemon-auto-chess (9000)`。

等游戏窗口出现 `⚔️ Listening on http://localhost:9000` 后，打开 http://localhost:9000/ 。

**先起 mongod 和模拟器、再起游戏**（脚本里的 10 秒等待就是为此），否则游戏启动时会连不上数据库。

## 四、两个远程仓库

本仓库配有两个 remote（注意命名：`origin` 是**自己的**仓库）：

| remote | 指向 | 用途 |
|---|---|---|
| `origin` | https://github.com/Kirby-YiBy/pokemon-Auto-Chess-Following-.git | **自己的仓库**，`git push` 推到这里 |
| `upstream` | https://github.com/keldaanCommunity/pokemonAutoChess | **原作者仓库**，只用来拉取更新 |

> 换机器或重新克隆自己的仓库后，记得补上 upstream：
> ```bash
> git remote add upstream https://github.com/keldaanCommunity/pokemonAutoChess.git
> ```

## 五、日常两条命令

```bash
cd "E:\我也不知道有什么用\哈哈\pokemonAutoChess"

# 1. 从原作者仓库取更新，把本地的定制提交叠在最上面
git pull --rebase upstream master

# 2. 推送到自己的仓库
git push origin master
```

> ⚠️ **推送必须在真正的终端窗口里跑**（Git Bash / cmd / PowerShell）。
> 如果通过 Claude Code 的 `!` 前缀执行，它是非交互式的：既弹不出 Git Credential Manager
> 的授权窗口，也接不了终端的用户名/密码输入，最后只会超时 —— 表现为"命令好像跑了但远端什么也没有"。
> 首次推送前先确认凭据已就绪（`git config --get credential.helper` 应输出 `manager`）。

然后按需重建：

```bash
npm install          # package.json 有变化时
npm run assetpack    # 资源有变化时（会重新生成 sw.js / atlas.json / assetsVersion）
npm run build-client # 或直接 npm run dev，它带 watch 会自动构建
# 最后关掉三个窗口，重新双击 start-offline.cmd 重启服务
```

### 为什么用 `git pull --rebase` 而不是直接 `git pull`

`master` 跟踪的是自己的 `origin/master`，所以裸跑 `git pull` 只会拉自己的仓库（没意义）。
从上游取更新必须写成 `git pull --rebase upstream master`。

用 `--rebase` 是因为本地定制是独立提交，rebase 让它始终贴在最新上游之上，历史保持线性；
用默认的 merge 每次都会多出一个合并提交。

**注意不要对 `upstream` 执行 `git push`** —— 你没有那个仓库的写权限（也正因如此不会误推成功）。
也**不需要**给原作者提 Pull Request，本地改动只留在自己的仓库。

### 几个必须知道的点

- **`.env` 不会被覆盖** —— 它在 `.gitignore` 里，你的 Firebase / Mongo 凭据是安全的
- **那 4 个文件是"可再生产物"，不要提交**：`package.json`（只有 `assetsVersion` 会变）、`app/public/dist/client/sw.js`、`app/public/src/assets/atlas.json`、`edit/assetpack/assetpack-cli-fork/bin/index.js`（这个是 Windows 换行符的假象，内容没变）。跑 `npm run assetpack` 会重新生成它们。看到它们在 `git status` 里是 modified，直接 `git checkout -- <文件>` 丢掉即可
- **数据库迁移**：版本号跳变时（例如 6.11 → 6.12），去 `db-commands/<新版本>/` 看有没有要手动跑的脚本
- **冲突只会出在上面那 5 个文件里**，改动都很小。真冲突了把冲突内容发出来即可

### 出问题了怎么办

```bash
git rebase --abort      # 放弃这次更新，回到 pull 之前的状态，不会丢东西
git log --oneline -5    # 看当前历史，本地定制提交长什么样
git status              # 看现在有什么改动
```

## 六、想回到联网模式

编辑 `.env`，把 `FIREBASE_AUTH_EMULATOR_HOST` 留空，然后重新构建客户端：

```bash
npm run build-client
```

注意：**模拟器的账号和真 Firebase 的账号是两套独立数据库**，互不相通。
