import strutils, asyncdispatch, net, times
import strformat
import posix
import asyncfile
import streams
import asyncssh2/futhark_B248CD8E528CCDE8




when defined(windows):
  import winlean



type
  AuthType = enum
    authPasswd
    authPubkey
    authPubkeyFile

  Session = ptr structlibssh2session
  Channel = ptr structlibssh2channel

  SSHSession* = ref object of RootObj
    sock: AsyncFD
    sess: Session
    host: string
    port: Port
    username: string
    case auth: AuthType
    of authPasswd:
      password: string
    of authPubkey:
      pk: bool # TODO
    of authPubkeyFile:
      pubKeyFile: string
      privKeyFile: string
      passphrase: string


  SSHChannel* = ref object
    session: SSHSession
    chan: Channel


proc waitsocket(s: SSHSession): Future[void] =
  result = newFuture[void]("waitsocket")
  let f = result
  let dir = s.sess.sessionBlockDirections()
  if (dir and LIBSSH2_SESSION_BLOCK_INBOUND) == LIBSSH2_SESSION_BLOCK_INBOUND:
    addRead(s.sock) do(fd: AsyncFD) -> bool:
      if not f.finished: f.complete()
      return true

  if (dir and LIBSSH2_SESSION_BLOCK_OUTBOUND) == LIBSSH2_SESSION_BLOCK_OUTBOUND:
    addWrite(s.sock) do(fd: AsyncFD) -> bool:
      if not f.finished: f.complete()
      return true


template withWaitSocket(rcode: untyped) =
  while true:
    rcode
    if rc == LIBSSH2_ERROR_EAGAIN:
      await waitsocket(s)
      continue
    elif rc < 0:
      checkError(rc)
      break
    else:
      break


proc checkError(err: csize) =
  if err != 0:
    raise newException(Exception, "ssh error: " & $err)

proc isAlive*(s: SSHSession): bool = not s.sess.isNil



proc disconnectfunc(s: Session, reason: cint, message: cstring, message_len: cint, language: cstring, language_len: cint, abstract: ptr[pointer]) {.cdecl.} =
  let sess = cast[SSHSession](abstract[])
  sess.sess = nil


proc handshake(s: SSHSession): Future[void] {.async.} =
  var rc: cint
  withWaitSocket:
    when defined(windows):
      rc = s.sess.sessionHandshake(cast[socketT](winlean.SocketHandle(s.sock)))
    else:
      rc = s.sess.sessionHandshake(cast[socketT](posix.SocketHandle(s.sock)))


proc userauthPasswordAsync(s: SSHSession): Future[void] {.async gcsafe.} =
  withWaitSocket:
    let rc = s.sess.userauthPasswordEx(s.username.cstring, s.username.len.cuint,  s.password.cstring, s.password.len.cuint, nil)
  
proc userauthPubkeyFileAsync(s: SSHSession): Future[void] {.async.} =
  withWaitSocket:
    let rc = s.sess.userauthPublickeyFromFileEx(s.username.cstring, s.username.len.cuint, s.pubkeyFile.cstring, s.privkeyFile.cstring, s.passphrase.cstring)


proc recreateSession(s: SSHSession) {.async gcsafe.} =
  s.sock = createAsyncNativeSocket()
  await s.sock.connect(s.host, s.port)
  s.sess = sessionInitEx(nil, nil, nil, nil)
  s.sess.sessionSetBlocking(0)
  s.sess.session_abstract()[] = cast[pointer](s)
  discard s.sess.session_callback_set(LIBSSH2_CALLBACK_DISCONNECT, cast[pointer](disconnectfunc))

  await s.handshake()
  case s.auth
  of authPasswd:
    await s.userauthPasswordAsync()
  of authPubkey:
    doASsert(false)
  of authPubkeyFile:
    await s.userauthPubkeyFileAsync()

proc restoreIfNeeded*(s: SSHSession) {.async gcsafe.} =
  if not s.isAlive:
    await s.recreateSession()

template initSSHIfNeeded() =
  var sshInited = false
  if not sshInited:
    init(0).checkError()

proc newSSHSession*(host: string, port: Port, username, password: string): Future[SSHSession] {.async gcsafe.} =
  initSSHIfNeeded()

  result = SSHSession(
    host: host, port: port,
    auth: authPasswd,
    username: username,
    password: password
    )
  await result.restoreIfNeeded()

proc newSSHSession*(host: string, port: Port, username, pubKeyFile, privKeyFile: string, passphrase: string = ""): Future[SSHSession] {.async.} =
  initSSHIfNeeded()
  result = SSHSession(
    host: host, port: port,
    auth: authPubkeyFile,
    username: username,
    pubKeyFile: pubKeyFile,
    privKeyFile: privKeyFile,
    passphrase: passphrase
    )
  await result.restoreIfNeeded()


proc shutdown*(s: SSHSession) =
  discard s.sess.sessionDisconnectEx(SSH_DISCONNECT_BY_APPLICATION, "Normal shutdown, thank you for playing", "")
  discard s.sess.sessionFree()
  s.sock.closeSocket()
  # libssh2.exit()
  # quit()


proc readString*(c: SSHChannel, readType: int): Future[string] {.async.} =
  var buffer: array[4096, char]
  var res = newStringStream()
  withWaitSocket:
    let rc = c.chan.channelReadEx(readType.cint, addr buffer, buffer.len.csize_t)
    if rc > 0:
      res.writeData(addr buffer, rc)
      continue
    let s = c.session
  res.setPosition(0)
  result = res.readAll()
  res.close()

template openSessionChannel(s: SSHSession,  action: typed): SSHChannel =
  var sch = SSHChannel()
  withWaitSocket:
    sch.chan = action
    
    if not sch.chan.isNil:
      sch.session = s
      break
    let rc {.inject.} = s.sess.sessionLastErrno()
  sch 

proc exec(channel: SSHChannel, command: string): Future[void] {.async.} =
  withWaitSocket:
    let rc = channel.chan.channelProcessStartup("exec", "exec".len, command, command.len.cuint)
    let s = channel.session


proc close*(channel: SSHChannel): Future[void] {.async.} =
  withWaitSocket:
    let rc = channel.chan.channelClose()
    let s = channel.session


proc free*(channel: SSHChannel): cint =
  channel.chan.channelFree()

proc disposeChannelAsync(ch: SSHChannel) {.async.} =
  await ch.close()
  discard ch.free()

proc exec*(s: SSHSession, command: string): Future[tuple[stdout, stderr: string,  exitCode: int]] {.async.} =
  let sch = s.openSessionChannel(s.sess.channelOpenEx("session", "session".len, 2*1024*1024, 32768, nil, 0))
  await sch.exec(command)
  result.stdout = await sch.readString(0)
  result.stderr = await sch.readString(1)
  result.exitCode = sch.chan.channelGetExitStatus()
  await disposeChannelAsync(sch)


proc lastError(s: Session): string =
  var buf: cstring
  discard session_last_error(s, addr buf, nil, 0)
  $buf


proc getFile*(s: SSHSession, remote: string, local: string) {.async.} =
  var 
    buffer: array[4096, char]
    fileInfo: structStat
    fileSize: int
    rc: int
    
  var sch = s.openSessionChannel(s.sess.scp_recv2(remote, addr fileInfo))
  when defined(windows):
    fileSize = fileInfo.stblksize.int
  else:
    fileSize = fileInfo.st_size.int
  echo fmt"Beginning to get the file:{remote}, size is:{fileSize}."
  let f = openAsync(local, fmWrite)
  while fileSize>0:
    withWaitSocket:
      rc = sch.chan.channelReadEx(0, addr buffer, buffer.len.csize_t)
      if rc > 0:
        fileSize = fileSize - rc
        if fileSize < 0:
          rc += fileSize
        await f.writeBuffer(addr buffer, rc)

  f.close()

proc putFile*(s: SSHSession, local: string, remote: string, mode: int = 438) {.async.} =
  var 
    buffer: array[4096, char]
    rc: csize
  let f = openAsync(local)
  let sz = f.getFileSize()

  var sch = s.openSessionChannel(s.sess.scpSendEx(remote, mode.cint, sz.csize_t, 0, 0))
  while true:
    var bytesRead = await f.readBuffer(addr buffer, buffer.len)
    if bytesRead <= 0: break
    withWaitSocket:
      rc = sch.chan.channelWriteEx(0, addr buffer, bytesRead.csize_t)
    if rc != bytesRead:
      raise newException(Exception, fmt"scp: fail to write data: {rc} wrote, {bytesRead} expected")
  f.close()

  withWaitSocket:
    let rc = channel_send_eof(sch.chan)
  withWaitSocket:
    let rc = channel_wait_eof(sch.chan)
  withWaitSocket:
    let rc = channel_wait_closed(sch.chan)

