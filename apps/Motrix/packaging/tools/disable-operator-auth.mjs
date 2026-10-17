#!/usr/bin/env node
/**
 * 关闭 Motrix Server 的 operator 口令鉴权（个人局域网使用，不想每次填口令）。
 *
 * 上游没有提供关闭开关：`src/server/index.ts` 里 `createApp()` 永远会传
 * `operatorAuth`（源码注释也写着 "the server entry ALWAYS provides it"）。
 * 但 `createApp()` 对「没传 operatorAuth」是有完整支持的：
 *
 *     const operatorSessions = opts.operatorAuth
 *       ? registerOperatorAuth(app, opts.operatorAuth)
 *       : undefined
 *     if (!operatorSessions) app.get('/rpc/auth/status', ... mode:'unrestricted')
 *
 * 渲染端只看 status.authed → 于是解锁页直接跳过，`/rpc/*`、`/api/*` 全部开放，
 * `/rpc/events` 实时通道照常工作（`session` 为 undefined 时广播器注册所有事件）。
 *
 * 这个脚本只对**已经构建好的** dist/server/index.mjs 做一处字符串改写：
 *
 *     operatorAuth:{operatorToken:   →   operatorAuth:(void 0)&&{operatorToken:
 *
 * 为什么这样写：对象字面量原样保留，语法合法，表达式求值为 undefined，
 * 于是 `opts.operatorAuth` 为假值。锚点带 `operatorToken:`，不会误伤诊断信息里的
 * `operatorAuth:{source:`。锚点必须恰好命中 1 次，否则立即失败（上游改了结构
 * 就让构建红，绝不发出一个"以为关了其实没关"的包）。
 *
 * 用法：node disable-operator-auth.mjs <path/to/index.mjs> [--check]
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'

const ANCHOR = 'operatorAuth:{operatorToken:'
const REPLACEMENT = 'operatorAuth:(void 0)&&{operatorToken:'

const [, , target, flag] = process.argv
if (!target) {
  console.error('usage: disable-operator-auth.mjs <index.mjs> [--check]')
  process.exit(2)
}

const source = readFileSync(target, 'utf8')
const occurrences = source.split(ANCHOR).length - 1
if (occurrences !== 1) {
  console.error(
    `[disable-operator-auth] 期望锚点出现 1 次，实际 ${occurrences} 次：${ANCHOR}\n` +
      '上游服务端结构可能变了，请重新核对 dist/server/index.mjs 再更新本脚本。'
  )
  process.exit(1)
}

if (source.includes(REPLACEMENT)) {
  console.log('[disable-operator-auth] 已经是开放模式，跳过')
  process.exit(0)
}
if (flag === '--check') {
  console.log('[disable-operator-auth] check: 锚点存在，可改写')
  process.exit(0)
}

const patched = source.replace(ANCHOR, REPLACEMENT)
writeFileSync(target, patched)

// 语法自检：ESM 也能过 node --check（Node >= 22 起支持）
try {
  execFileSync(process.execPath, ['--check', target], { stdio: 'pipe' })
} catch (error) {
  writeFileSync(target, source)
  console.error('[disable-operator-auth] 改写后语法检查失败，已回滚')
  console.error(String(error.stderr ?? error))
  process.exit(1)
}

const remaining = readFileSync(target, 'utf8').split(ANCHOR).length - 1
if (remaining !== 0) {
  console.error('[disable-operator-auth] 改写后仍有锚点残留，构建中止')
  process.exit(1)
}
console.log(`[disable-operator-auth] 已关闭 operator 鉴权：${target}`)
