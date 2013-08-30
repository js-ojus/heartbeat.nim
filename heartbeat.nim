# A script to try out small examples.

import httpclient
import json
import os
import osproc
import smtp
import sockets
import streams
import strutils
import times

## Is the site responding?
proc isSiteUp(url: string, timeout: int): tuple[msg: string, ok: bool] =
  try:
    let res = httpclient.request(url,
                                 httpMethod = httpclient.httpHEAD,
                                 timeout = timeout * 1000)
    if "200 OK" == res.status:
      return (res.status, true)
    else:
      return (res.status, false)
  except ESSL:
    return ("SSL error; the site does not support 'https'", false)
  except ETimeout:
    return ("Timeout error", false)
  except:
    return ("Unknown error", false)

## Does the given server exist?
proc doesServerExist(server: string): bool =
  let p = osproc.startProcess("/usr/bin/dig",
                              args = @["+nocmd",
                                       "+noquestion",
                                       "+noauthority",
                                       "+noadditional",
                                       "+nostats",
                                       "@8.8.8.8",
                                       server])
  let sout = p.outputStream()
  discard p.waitForExit()

  while not sout.atEnd():
    var ln = streams.readLine(sout)
    let idx1 = ln.find(", ANSWER:")
    if idx1 > -1:
      let idx3 = ln.find(",", idx1+1)
      let idx2 = ln.rfind(" ", idx3)
      let n = parseInt(ln[idx2+1..idx3-1])
      if n > 0:
        result = true
      else:
        result = false
      break

  p.close()
  return

## Compose the alert message.
proc alertMessage(url: string,
                  msg: string,
                  tAt: string,
                  tos: seq[string]): string =
  let sub = "[heartbeat] Alert for: " & url
  let body = """
This is a down-time alert message.
Site: $1.
Status: $2.
At: $3.
""".format(url, msg, tAt)

  return $smtp.createMessage(sub, body, tos)

## Send the alert message.
proc alert(msg: string,
           tos: seq[string],
           conf: PJsonNode): tuple[msg: string, ok: bool] =
  let server = conf["server"].str
  let port = int(conf["port"].num)
  let faddr = conf["address"].str
  try:
    var cxn = smtp.connect(server, port, ssl = true, debug = false)
    cxn.auth(conf["user"].str, conf["password"].str)
    cxn.sendMail(fromaddr = faddr, toaddrs = tos, msg = $msg)
    return ("", true)
  except:
    return (getCurrentExceptionMsg(), false)

## Read the configuration.
proc config(): tuple[conf: PJsonNode, ok: bool] =
  var conf: PJsonNode
  try:
    conf = json.parseFile("heartbeat.json")
    return (conf, true)
  except:
    return (nil, false)

# Main.
when isMainModule:
  # Read the configuration first.
  let res = config()
  if not res.ok:
    echo("!! Error reading the configuration file.")
    echo("!! Please specify all the keys and values properly.\n")
    quit()
  let conf = res.conf

  var tos: seq[string] = @[]
  for taddr in conf["to"].elems:
    insert(tos, taddr.str)

  while true:
    # Open the log file.
    let log = Open("heartbeat.log", fmAppend)

    for site in conf["sites"].elems:
      let server = site["server"].str
      let url = site["protocol"].str & "://" & server
      let time = times.getLocalTime(times.getTime())
      let tzs = times.getTzname()
      let tAt = $time & " " & tzs.nonDST & "/" & tzs.DST

      if not doesServerExist(server):
        writeln(log, "$1 : [ERROR] $2 : $3.".format(tAt, server, "could not be resolved/reached"))
        let msg = alertMessage(server, "could not be resolved/reached", tAt, tos)
        let res = alert(msg, tos, conf)
        if not res.ok:
          writeln(log, "$1 : [ERROR] $2 : unable to send alert - $3.".format(tAt, url, res.msg))
        continue

      let res = isSiteUp(url, timeout = int(site["timeout"].num))
      if res.ok:
        writeln(log, "$1 : [SUCCESS] $2.".format(tAt, url))
      else:
        writeln(log, "$1 : [ERROR] $2 : $3.".format(tAt, url, res.msg))
        let msg = alertMessage(url, res.msg, tAt, tos)
        let res = alert(msg, tos, conf)
        if not res.ok:
          writeln(log, "$1 : [ERROR] $2 : unable to send alert - $3.".format(tAt, url, res.msg))

      FlushFile(log)

    Close(log)
    sleep(int(conf["interval"].num) * 1000)
