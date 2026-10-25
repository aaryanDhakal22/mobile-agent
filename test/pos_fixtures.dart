// 2.1.0 agent payloads: POS (SoftTouch) orders from the store hub.

/// A POS (SoftTouch) delivery as the agent stores it: accepted, no kitchen
/// number, the check # in `display_number`, every 2.1.0 status field set.
const posDeliveryJson = r'''
{
  "order": {
    "id": "pos-0001",
    "source": "pos",
    "source_event_id": "softtouch:1276237",
    "money": {"subtotal_cents": 2000, "tax_cents": 120, "tip_cents": 300, "total_cents": 2420},
    "customer": {"display_name": "Pat Kim", "phone": "4105550123"},
    "fulfillment": {"type": "delivery", "address": {"line1": "12 Yorke Rd", "city": "Towson", "state": "MD", "postal_code": "21204"}},
    "items": [{"name": "14\" Cheese Pizza", "quantity": 1, "unit_price_cents": 1199, "line_total_cents": 1199,
               "children": [{"name": "Pineapple", "quantity": 1, "unit_price_cents": 150, "line_total_cents": 150}]}],
    "placed_at": "2026-10-25T17:00:00Z"
  },
  "status": {
    "state": "accepted",
    "batch_id": 9,
    "prep_minutes": 35,
    "accepted_at": "2026-10-25T17:01:00Z",
    "estimated_ready_at": "2026-10-25T17:36:00Z",
    "ext_source": "softtouch",
    "ext_ref": "1276237",
    "display_number": 99,
    "paid": false,
    "cash_due_cents": 2120,
    "tip_cents": 300,
    "board_hidden": false,
    "sent_at": "2026-10-25T17:01:00Z",
    "local_only": true,
    "flag": {"text": "Settle manually: unmapped item X", "severity": "serious"},
    "pos_check_number": 4410,
    "pos_driver_note": "POS says #12 (not clocked in)"
  },
  "geo": {
    "state": "check",
    "candidates": [
      {"label": "12 York Rd, Towson, MD 21204", "line1": "12 York Rd", "city": "Towson", "state": "MD", "postal_code": "21204"},
      {"label": "12 Yorke Ct, Towson, MD 21286", "line1": "12 Yorke Ct", "city": "Towson", "state": "MD", "postal_code": "21286", "lat": 39.4, "lng": -76.6},
      {"label": "12 Yorkshire Dr, Towson, MD 21286"},
      {"label": "a fourth one is ignored"}
    ],
    "confirmed_address": {"line1": "12 York Rd", "city": "Towson", "state": "MD", "postal_code": "21204"}
  }
}
''';
