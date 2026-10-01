-- Apply-time checks give precise sync errors; these additive triggers enforce
-- the same logical links atomically when a competing mutation commits first.
-- No foreign key is added: existing document links survive client tombstones.
CREATE TRIGGER v2_quote_client_insert
BEFORE INSERT ON quotes
WHEN NEW.deleted_at IS NULL AND NEW.client_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM clients AS c
    WHERE c.id = NEW.client_id AND c.user_id = NEW.user_id AND c.profile_id IS NEW.profile_id
      AND (c.deleted_at IS NULL OR EXISTS (
        SELECT 1 FROM quotes AS previous
        WHERE previous.id = NEW.id AND previous.user_id = NEW.user_id
          AND previous.profile_id IS NEW.profile_id AND previous.client_id = NEW.client_id
      ))
  )
BEGIN
  SELECT RAISE(ABORT, 'invalid v2 quote client link');
END;

CREATE TRIGGER v2_quote_client_update
BEFORE UPDATE OF user_id, profile_id, client_id, deleted_at ON quotes
WHEN NEW.deleted_at IS NULL AND NEW.client_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM clients AS c
    WHERE c.id = NEW.client_id AND c.user_id = NEW.user_id AND c.profile_id IS NEW.profile_id
      AND (c.deleted_at IS NULL OR (
        OLD.user_id = NEW.user_id AND OLD.profile_id IS NEW.profile_id AND OLD.client_id = NEW.client_id
      ))
  )
BEGIN
  SELECT RAISE(ABORT, 'invalid v2 quote client link');
END;

CREATE TRIGGER v2_invoice_client_insert
BEFORE INSERT ON invoices
WHEN NEW.deleted_at IS NULL AND NEW.client_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM clients AS c
    WHERE c.id = NEW.client_id AND c.user_id = NEW.user_id AND c.profile_id IS NEW.profile_id
      AND (c.deleted_at IS NULL OR EXISTS (
        SELECT 1 FROM invoices AS previous
        WHERE previous.id = NEW.id AND previous.user_id = NEW.user_id
          AND previous.profile_id IS NEW.profile_id AND previous.client_id = NEW.client_id
      ))
  )
BEGIN
  SELECT RAISE(ABORT, 'invalid v2 invoice client link');
END;

CREATE TRIGGER v2_invoice_client_update
BEFORE UPDATE OF user_id, profile_id, client_id, deleted_at ON invoices
WHEN NEW.deleted_at IS NULL AND NEW.client_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM clients AS c
    WHERE c.id = NEW.client_id AND c.user_id = NEW.user_id AND c.profile_id IS NEW.profile_id
      AND (c.deleted_at IS NULL OR (
        OLD.user_id = NEW.user_id AND OLD.profile_id IS NEW.profile_id AND OLD.client_id = NEW.client_id
      ))
  )
BEGIN
  SELECT RAISE(ABORT, 'invalid v2 invoice client link');
END;

CREATE TRIGGER v2_follow_up_insert
BEFORE INSERT ON client_follow_ups
WHEN NEW.deleted_at IS NULL AND NEW.profile_id IS NOT NULL AND NEW.client_id IS NOT NULL AND (
  NOT EXISTS (
    SELECT 1 FROM profiles AS p
    WHERE p.id = NEW.profile_id AND p.user_id = NEW.user_id AND p.type = 'business' AND p.deleted_at IS NULL
  ) OR NOT EXISTS (
    SELECT 1 FROM clients AS c
    WHERE c.id = NEW.client_id AND c.user_id = NEW.user_id AND c.profile_id = NEW.profile_id AND c.deleted_at IS NULL
  )
)
BEGIN
  SELECT RAISE(ABORT, 'invalid v2 follow-up scope');
END;

CREATE TRIGGER v2_follow_up_update
BEFORE UPDATE OF user_id, profile_id, client_id, deleted_at ON client_follow_ups
WHEN NEW.deleted_at IS NULL AND NEW.profile_id IS NOT NULL AND NEW.client_id IS NOT NULL AND (
  NOT EXISTS (
    SELECT 1 FROM profiles AS p
    WHERE p.id = NEW.profile_id AND p.user_id = NEW.user_id AND p.type = 'business' AND p.deleted_at IS NULL
  ) OR NOT EXISTS (
    SELECT 1 FROM clients AS c
    WHERE c.id = NEW.client_id AND c.user_id = NEW.user_id AND c.profile_id = NEW.profile_id AND c.deleted_at IS NULL
  )
)
BEGIN
  SELECT RAISE(ABORT, 'invalid v2 follow-up scope');
END;

CREATE TRIGGER v2_catalog_item_insert
BEFORE INSERT ON catalog_items
WHEN NEW.deleted_at IS NULL AND NEW.profile_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM profiles AS p
  WHERE p.id = NEW.profile_id AND p.user_id = NEW.user_id AND p.type = 'business' AND p.deleted_at IS NULL
)
BEGIN
  SELECT RAISE(ABORT, 'invalid v2 catalog profile');
END;

CREATE TRIGGER v2_catalog_item_update
BEFORE UPDATE OF user_id, profile_id, deleted_at ON catalog_items
WHEN NEW.deleted_at IS NULL AND NEW.profile_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM profiles AS p
  WHERE p.id = NEW.profile_id AND p.user_id = NEW.user_id AND p.type = 'business' AND p.deleted_at IS NULL
)
BEGIN
  SELECT RAISE(ABORT, 'invalid v2 catalog profile');
END;

CREATE TRIGGER v2_client_profile_move
BEFORE UPDATE OF profile_id ON clients
WHEN NEW.profile_id IS NOT OLD.profile_id AND (
  EXISTS (
    SELECT 1 FROM quotes AS q
    WHERE q.user_id = OLD.user_id AND q.profile_id IS OLD.profile_id AND q.client_id = OLD.id AND q.deleted_at IS NULL
  ) OR EXISTS (
    SELECT 1 FROM invoices AS i
    WHERE i.user_id = OLD.user_id AND i.profile_id IS OLD.profile_id AND i.client_id = OLD.id AND i.deleted_at IS NULL
  ) OR EXISTS (
    SELECT 1 FROM client_follow_ups AS f
    WHERE f.user_id = OLD.user_id AND f.profile_id IS OLD.profile_id AND f.client_id = OLD.id AND f.deleted_at IS NULL
  )
)
BEGIN
  SELECT RAISE(ABORT, 'v2 client profile move invalidates live links');
END;
