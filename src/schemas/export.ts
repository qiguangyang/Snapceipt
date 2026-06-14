import { z } from "zod";

const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "expected YYYY-MM-DD");

/**
 * POST /export body (spec §4.2). `toEmail` is required iff format === "accountant"
 * (enforced by superRefine so the failure is a clean VALIDATION_FAILED). The
 * from<=to check is done in the route (it also resolves the profile), not here.
 */
export const exportRequestSchema = z
  .object({
    profileId: z.string().min(1),
    format: z.enum(["pdf", "csv", "accountant", "bas"]),
    from: isoDate,
    to: isoDate,
    toEmail: z.string().email().optional(),
    // BAS pack manual params (spec §4.4). Only paygInstalmentCents is user-editable
    // in v1; absent => 0 (the engine defaults the rest to 0).
    bas: z
      .object({ paygInstalmentCents: z.number().int().nonnegative().optional() })
      .optional(),
  })
  .superRefine((val, ctx) => {
    if (val.format === "accountant" && !val.toEmail) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["toEmail"],
        message: "toEmail is required when format is 'accountant'",
      });
    }
  });

export type ExportRequest = z.infer<typeof exportRequestSchema>;
