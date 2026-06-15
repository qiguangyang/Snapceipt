import { describe, expect, it } from "vitest";
import { inferCategory } from "../src/lib/receiptCategory";

describe("inferCategory", () => {
  it("maps known merchants to their category (case-insensitive)", () => {
    expect(inferCategory("WOOLWORTHS 1234", [])).toBe("groceries");
    expect(inferCategory("Shell Coles Express", [])).toBe("fuel");
    expect(inferCategory("The Coffee Club", [])).toBe("meals");
    expect(inferCategory("Uber *Trip", [])).toBe("travel");
    expect(inferCategory("OFFICEWORKS", [])).toBe("office");
    expect(inferCategory("Chemist Warehouse", [])).toBe("health");
    expect(inferCategory("Bunnings Warehouse", [])).toBe("home");
    expect(inferCategory("ADOBE", [])).toBe("software");
  });
  it("falls back to a line item when the merchant is unknown", () => {
    expect(inferCategory("Unknown Store", ["Flat White", "Bacon roll"])).toBe("office"); // no kw -> default
    expect(inferCategory("Suncorp", ["Parking 1hr"])).toBe("travel");
  });
  it("defaults to office when nothing matches", () => {
    expect(inferCategory("Zzzqqq Pty Ltd", [])).toBe("office");
  });
});
