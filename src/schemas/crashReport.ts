import { z } from "zod";

/**
 * POST /crash-reports body. iOS posts MetricKit diagnostics (MXCrashDiagnostic /
 * MXHangDiagnostic) reduced to a small JSON envelope. `payload` is the raw
 * diagnostic dictionary (MXDiagnostic.dictionaryRepresentation) — stored verbatim
 * as JSON for later triage; we don't model its full shape. Server-only; never
 * synced. occurredAt is epoch ms.
 */
export const crashReportSchema = z.object({
  kind: z.enum(["crash", "hang"]),
  appVersion: z.string().min(1),
  osVersion: z.string().min(1),
  deviceModel: z.string().min(1),
  occurredAt: z.number().int().nonnegative(),
  payload: z.record(z.string(), z.unknown()),
});

export type CrashReport = z.infer<typeof crashReportSchema>;
