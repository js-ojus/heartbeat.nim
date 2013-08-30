# A script to try out small examples.

import
  httpclient, json, os, osproc, pegs, smtp, sockets, streams, strutils, times

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
    let re = pegs.peg("""',' \s 'ANSWER:' \s {\d+} ','""")
    var m: seq[string] = @[""]
    if pegs.find(ln, re, m) >= 0:
      let n = parseInt(m[0])
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
                  tos: seq[string],
                  conf: PJsonNode): string =
  let sub = "[heartbeat] Alert for: " & url
  let body = "This is a down-time alert message.\n$1\n" % [msg]
  let faddr = "$1 <$2>" % [conf["name"].str, conf["address"].str]

  return $smtp.createMessage(sub, body, tos, @[], [("From", faddr)])

## Send the alert message.
proc alert(emsg: string,
           msg: string,
           tos: seq[string],
           conf: PJsonNode,
           log: TFile): tuple[msg: string, ok: bool] =
  log.writeln(emsg)

  let server = conf["server"].str
  let port = int(conf["port"].num)
  let faddr = conf["address"].str
  try:
    var cxn = smtp.connect(server, port, ssl = true, debug = false)
    cxn.auth(conf["user"].str, conf["password"].str)
    cxn.sendMail(fromaddr = faddr, toaddrs = tos, msg = $msg)
    return ("", true)
  except:
    let errmsg = getCurrentExceptionMsg()
    log.writeln("$1 \n\t[ERROR] : unable to send alert : $2." % [emsg, errmsg])
    return (errmsg, false)

## Read the configuration.
proc config(): tuple[conf: PJsonNode, ok: bool] =
  var conf: PJsonNode
  try:
    conf = json.parseFile("heartbeat.json")
    return (conf, true)
  except:
    return (nil, false)

## Collect all the e-mail addresses to send the alert to.
proc collectAddrs(conf: PJsonNode): seq[string] =
  var tos: seq[string] = @[]
  for taddr in conf["to"].elems:
    insert(tos, taddr.str)
  return tos

## Main.
proc main() =
  # Read the configuration first.
  let res = config()
  if not res.ok:
    echo("!! Error reading the configuration file.")
    echo("!! Please specify all the keys and values properly.\n")
    quit()
  let conf = res.conf

  let tos = collectAddrs(conf)

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
        let emsg = "$1 : [ERROR] $2 : $3." % [tAt, server, "could not be resolved/reached"]
        let msg = alertMessage(server, emsg, tos, conf)
        discard alert(emsg, msg, tos, conf, log)
        continue

      let res = isSiteUp(url, timeout = int(site["timeout"].num))
      if res.ok:
        log.writeln("$1 : [SUCCESS] $2." % [tAt, url])
      else:
        let emsg = "$1 : [ERROR] $2 : $3." % [tAt, url, res.msg]
        let msg = alertMessage(url, emsg, tos, conf)
        discard alert(emsg, msg, tos, conf, log)

      FlushFile(log)

    Close(log)
    sleep(int(conf["interval"].num) * 1000)

#
when isMainModule:
  main()
