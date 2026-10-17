#!/usr/bin/env node
// ==============================================================================
// 去掉解锁页里对 MOTRIX_OPERATOR_TOKEN 的提示
//
// 上游 Web 面板的解锁页文案是编译进 renderer 包里的（en-US 在主 chunk，
// 其余 25 种语言各一个 locale chunk），本包不提供/不使用这个环境变量，
// 所以把这几条文案换成本机的真实口令路径。
//
// 用法：node patch-renderer-hint.mjs <dist/renderer-web 目录>
//
// 设计：幂等；找不到就什么都不做（上游哪天自己删掉了也正常）；改完自检，
//      包里再残留 MOTRIX_OPERATOR_TOKEN 就报错退出。
// ==============================================================================
import { readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import path from 'node:path'

const TOKEN_PATH = '/vol1/@appdata/Motrix/data/operator-token'
const HELP_TEXT = `读取口令（Read the operator token）：sudo cat ${TOKEN_PATH} ，然后粘贴到下面。`
const ERROR_TEXT = `口令不正确（Invalid operator token）。请核对 ${TOKEN_PATH} 。`
const ENV_NAME = 'MOTRIX_OPERATOR_TOKEN'

const root = process.argv[2]
if (!root) {
  console.error('usage: patch-renderer-hint.mjs <renderer-web dir>')
  process.exit(2)
}

function* walk(dir) {
  for (const entry of readdirSync(dir)) {
    const full = path.join(dir, entry)
    if (statSync(full).isDirectory()) yield* walk(full)
    else if (full.endsWith('.js')) yield full
  }
}

// help:`…MOTRIX_OPERATOR_TOKEN…` / error:`…MOTRIX_OPERATOR_TOKEN…`
const MESSAGE = new RegExp(`(help|error):\`[^\`]*${ENV_NAME}[^\`]*\``, 'g')

let filesTouched = 0
let messagesReplaced = 0
let leftovers = 0

for (const file of walk(root)) {
  const original = readFileSync(file, 'utf8')
  if (!original.includes(ENV_NAME)) continue

  let text = original.replace(MESSAGE, (_match, key) => {
    messagesReplaced += 1
    return `${key}:\`${key === 'help' ? HELP_TEXT : ERROR_TEXT}\``
  })

  // 兜底：其它消息（例如凭据校验错误）里若还提到这个环境变量，
  // 换成 language-neutral 的文件名，避免界面上再出现它。
  if (text.includes(ENV_NAME)) {
    const count = text.split(ENV_NAME).length - 1
    leftovers += count
    text = text.split(ENV_NAME).join('operator-token')
  }

  if (text !== original) {
    writeFileSync(file, text)
    filesTouched += 1
  }
}

console.log(
  `[patch-renderer] ${messagesReplaced} 条解锁文案已替换，${leftovers} 处零散提及已改写，涉及 ${filesTouched} 个文件`
)

// 自检：整个 renderer-web 里不应再有该环境变量名
let remaining = 0
for (const file of walk(root)) {
  const text = readFileSync(file, 'utf8')
  remaining += text.split(ENV_NAME).length - 1
}
if (remaining > 0) {
  console.error(`[patch-renderer] 仍有 ${remaining} 处 ${ENV_NAME}，补丁未生效`)
  process.exit(7)
}
console.log('[patch-renderer] 自检通过：渲染包里已无 MOTRIX_OPERATOR_TOKEN')
