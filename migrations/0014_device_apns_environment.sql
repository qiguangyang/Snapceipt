-- Per-device APNs environment so the worker sends to the correct APNs host.
-- Development builds (Xcode/devicectl, aps-environment=development) register a
-- SANDBOX token that production APNs rejects with BadDeviceToken; this column
-- lets the device report its environment so sendPush picks api.sandbox.push.apple.com
-- vs api.push.apple.com. NULL is treated as 'production' (the safe default for any
-- existing/App-Store device that predates this column).
ALTER TABLE devices ADD COLUMN apns_environment TEXT;
