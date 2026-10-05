# Intiface / Buttplug protocol, as verified against the live server

Observed against intiface-engine 5.0.4; where the spec was ambiguous, server
behavior took precedence.

## Transport

- Any HTTP path upgrades successfully (`/`, `/intiface`, `/websocket`); the path
  is not checked. `Sec-WebSocket-Protocol` is not required.
- The upgrade response's `Sec-WebSocket-Accept` is computed from the request key
  exactly as RFC 6455 specifies, so the standard check applies.

## Envelope

Every message is a JSON **array** of single-key objects:

```
[{"MessageName":{"Field":value,...}}]
```

A bare object is not answered at all. The server logs it as an invalid message
and drops it silently, which makes a wrong envelope look exactly like a network
problem. This is why a probe of `{"RequestServerInfo":{}}` gets no reply while
`[{"RequestServerInfo":{...}}]` does.

## Handshake

```
-> [{"RequestServerInfo":{"Id":1,"ClientName":"Haptic Noita","ProtocolVersionMajor":4,"ProtocolVersionMinor":0}}]
<- [{"ServerInfo":{"Id":1,"MaxPingTime":0,"ProtocolVersionMajor":4,"ProtocolVersionMinor":0,"ServerName":"Intiface Server"}}]
```

`MaxPingTime: 0` means the server does not require pings. `Id` is matched on the
reply. Re-sending `RequestServerInfo` on the same connection fails with
`ButtplugHandshakeError: HandshakeAlreadyHappened`.

For nonzero `MaxPingTime`, the client sends `Ping` with a fresh `Id` at half
the advertised interval while the WebSocket is open. The zero-timeout server
used for the checks below rejects unsolicited `Ping` messages.

## Devices

```
-> [{"RequestDeviceList":{"Id":2}}]
<- [{"DeviceList":{"Devices":{"0":{...}},"Id":2}}]
```

`Devices` is an object keyed by the **stringified** device index, not an array.
The observed device:

```
DeviceName            Lovense Ferri
DeviceIndex           0
DeviceMessageTimingGap 100
DeviceFeatures        { "0": { Output: { Vibrate: { Value: [0,20] } } },
                          "1": { Input:  { Battery: { Command:["Read"], Value:[[0,100]] } } } }
```

Two things matter:

- **`Value` is a step range in the device's own units, not 0..1.** The Ferri
  takes 0..20. Sending `0.2` is not a 20% setting; it is step 0.
- **`DeviceMessageTimingGap` is the minimum interval between commands to that
  device**, 100 ms here. Commands faster than that are the server's problem to
  queue, and on hardware it is ours to avoid.

## Output

The v4 generic output message uses `Command`, not `Output`. `Output` is not
merely ignored, it fails schema validation and the frame is dropped.

```
-> [{"OutputCmd":{"Id":2,"DeviceIndex":0,"FeatureIndex":0,"Command":{"Vibrate":{"Value":4}}}}]
<- [{"Ok":{"Id":2}}]

-> [{"StopCmd":{"Id":4,"DeviceIndex":0}}]
<- [{"Ok":{"Id":4}}]
```

The mod tracks `OutputCmd` and `StopCmd` IDs until `Ok` or `Error`. A matching
`Error` invalidates the assumed output level and prompts a retry of the current
desired level. Unrelated `Error` messages are logged without changing output
state.

`Value` must be an integer. Other shapes that were tried and rejected, each with
a schema-validation error naming the expected field:

| Attempted | Verdict |
|---|---|
| `OutputCmd` with `Output` | rejected: `Command` is required, `Output` is an additional property |
| `OutputCmdWithParameters` | not in the v4 schema at all |
| `VibrateCmd` (v3 shape, `Speeds`) | only exists under `MessageSpecV1` |
| `VibrateDeviceCmd` | v1/v3 only |
| `Ping` | answered with `ButtplugPingError: PingTimerNotRunning`, because the timer only runs when `MaxPingTime > 0` |

## Strictness

The server validates every message against a JSON schema and **closes the
connection** on anything it cannot parse, including unknown extra fields. A
message padded with an invented key such as `Pad` kills the connection even
though the JSON is well formed. Only real spec fields may be sent.

Practical consequence: large-frame behaviour cannot be tested against this
server. A 300-byte payload in a legal field is fine; anything approaching 64 KB
is refused, so the 64-bit length encoding cannot be exercised against this
server.

## Source of truth

`buttplug-rs`, `crates/buttplug_core/src/message/v4/output_cmd.rs`, which
defines `OutputCmdV4` as `{ Id, DeviceIndex, FeatureIndex, Command }` with
`Command` an externally tagged enum, giving `{"Vibrate":{"Value":N}}`.
