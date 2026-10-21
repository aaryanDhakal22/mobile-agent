// Realistic agent payloads (shapes from contract/agent.md §2.1 and
// contract/main.md §10.1), as the agent's Go encoder writes them: absent
// optional fields are omitted, timestamps are RFC3339 UTC.

/// An arrived pickup order (no floor fields yet), routed items with size,
/// modifiers and notes.
const arrivedPickupJson = r'''
{
  "order": {
    "id": "01963a40-7c1e-7a51-9d2b-5d1f0c2a0001",
    "tenant_id": "00000000-0000-0000-0000-000000000001",
    "location_id": "00000000-0000-0000-0000-000000000002",
    "source": "online",
    "source_event_id": "61124111",
    "status": "received",
    "currency": "USD",
    "money": {
      "subtotal_cents": 2622,
      "tax_cents": 181,
      "tip_cents": 302,
      "discounts": [{"type":"promo","code":"SUMMER10","label":"Summer 10% off","amount_cents":350}],
      "total_cents": 2755
    },
    "customer": {"display_name": "Erik Davis", "email": "ERIK_TAILS11@YAHOO.COM", "phone": "4432077156"},
    "fulfillment": {"type": "pickup"},
    "items": [
      {
        "id": "0196a-item-1", "position": 0, "sku": "PIZZA-12-MED",
        "name": "Regular Tomato Cheese Pizza", "size": "12 Medium", "quantity": 1,
        "unit_price_cents": 999, "line_total_cents": 1149, "notes": "well done",
        "children": [
          {"id":"0196a-mod-1","position":0,"name":"Add Pineapple","quantity":1,"unit_price_cents":150,"line_total_cents":150,"notes":"add"}
        ],
        "menu_item_id": "0196a-menu-1", "printer_id": "0196a-printer-1", "routing": "matched"
      },
      {
        "id": "0196a-item-2", "position": 1, "name": "Garlic Knots", "quantity": 2,
        "unit_price_cents": 599, "line_total_cents": 1198, "routing": "unmatched"
      }
    ],
    "payments": [{"method":"card","amount_cents":2755,"last4":"0303","auth_code":"052482"}],
    "placed_at": "2026-05-12T17:41:50Z",
    "received_at": "2026-05-12T17:42:00.123Z",
    "source_metadata": {"store_id": 3282, "store_name": "Lombardi's Pizza", "tver": "1.0.0"}
  },
  "status": {
    "state": "arrived",
    "arrival_date": "2026-05-12T17:42:00Z",
    "batch_id": 7
  }
}
''';

/// A delivery order out with a driver.
const onDeliveryJson = r'''
{
  "order": {
    "id": "01963a40-7c1e-7a51-9d2b-5d1f0c2a0002",
    "tenant_id": "00000000-0000-0000-0000-000000000001",
    "location_id": "00000000-0000-0000-0000-000000000002",
    "source": "online",
    "source_event_id": "61124112",
    "status": "accepted",
    "currency": "USD",
    "money": {
      "subtotal_cents": 3100,
      "tax_cents": 186,
      "tip_cents": 500,
      "fees": [{"type":"delivery","label":"Delivery Fee","amount_cents":400}],
      "total_cents": 4186
    },
    "customer": {"display_name": "Maria Lopez", "phone": "4105550111"},
    "fulfillment": {
      "type": "delivery",
      "address": {"line1": "931 Taylor Avenue", "line2": "Apt 4", "city": "Towson", "state": "MD", "postal_code": "21286", "notes": "Ring twice"}
    },
    "items": [
      {"id":"0196b-item-1","position":0,"name":"Chicken Parm Sub","size":"Large","quantity":1,"unit_price_cents":3100,"line_total_cents":3100,"routing":"matched","printer_id":"p1"}
    ],
    "payments": [{"method":"card","amount_cents":4186,"last4":"1111"}],
    "placed_at": "2026-05-12T17:10:00Z",
    "received_at": "2026-05-12T17:10:01Z",
    "kitchen_order_number": 1104,
    "estimated_ready_at": "2026-05-12T17:31:01Z",
    "driver_name": "Sam"
  },
  "status": {
    "state": "on_delivery",
    "arrival_date": "2026-05-12T17:10:01Z",
    "printed_date": "2026-05-12T17:11:01Z",
    "batch_id": 7,
    "kitchen_number": 1104,
    "prep_minutes": 20,
    "estimated_ready_at": "2026-05-12T17:31:01Z",
    "accepted_at": "2026-05-12T17:11:00Z",
    "ready_at": "2026-05-12T17:29:00Z",
    "out_at": "2026-05-12T17:33:00Z",
    "driver_id": "d-sam",
    "driver_name": "Sam"
  }
}
''';

/// A legacy row: written before floor fields / routing / size existed. Its
/// state predates the floor flow ("accepted" with only printed_date) and the
/// snapshot lacks fulfillment, money breakdown and customer email.
const legacyJson = r'''
{
  "order": {
    "id": "01963a40-7c1e-7a51-9d2b-5d1f0c2a0003",
    "source": "online",
    "source_event_id": "61124001",
    "money": {"total_cents": 1599},
    "customer": {"display_name": ""},
    "items": [{"name": "Large Cheese Pizza", "quantity": 1, "line_total_cents": 1599}],
    "placed_at": "0001-01-01T00:00:00Z",
    "received_at": "2026-04-01T12:00:00Z"
  },
  "status": {
    "state": "accepted",
    "arrival_date": "2026-04-01T12:00:00Z",
    "printed_date": "2026-04-01T12:01:00Z"
  }
}
''';

const floorJson = r'''
{"batch":{"id":7,"opened_at":"2026-05-12T10:00:00Z","order_count":12},"kitchen_next":1105,"last_prep_minutes":20,"prep_choices":[10,15,20,30,45,60],"unsynced_events":3,"driver_reset_time":"10:00"}
''';

/// `GET /api/drivers` in queue order: Lee is clocked out (`off`, no
/// `clocked_in_at`) and sits between drivers in the queue.
const driversJson = r'''
[
  {"id":"d-ana","name":"Ana","position":1,"status":"available","clocked_in_at":"2026-05-12T15:58:00Z","last_returned_at":"2026-05-12T17:20:00Z","deliveries":2},
  {"id":"d-lee","name":"Lee","position":2,"status":"off","deliveries":0},
  {"id":"d-sam","name":"Sam","position":3,"status":"out","clocked_in_at":"2026-05-12T16:05:00Z","deliveries":1},
  {"id":"d-joe","name":"Joe","position":4,"status":"available","clocked_in_at":"2026-05-12T16:30:00Z","deliveries":0}
]
''';

/// A roster from an agent that predates clock-in: no `off`, no
/// `clocked_in_at`.
const legacyDriversJson = r'''
[
  {"id":"d-ana","name":"Ana","position":1,"status":"available","deliveries":2},
  {"id":"d-sam","name":"Sam","position":2,"status":"out","deliveries":1},
  {"id":"d-old","name":"Old","position":3}
]
''';

/// `GET /api/drivers/shifts?days=7`, newest first: one open, one closed by
/// staff, one closed by the daily reset.
const shiftsJson = r'''
[
  {"id":"s-3","driver_id":"d-joe","driver_name":"Joe","batch_id":7,"clock_in":"2026-05-12T16:30:00Z","auto_out":false},
  {"id":"s-2","driver_id":"d-lee","driver_name":"Lee","batch_id":7,"clock_in":"2026-05-12T11:00:00Z","clock_out":"2026-05-12T15:30:00Z","auto_out":false},
  {"id":"s-1","driver_id":"d-sam","driver_name":"Sam","batch_id":6,"clock_in":"2026-05-11T16:00:00Z","clock_out":"2026-05-12T14:00:00Z","auto_out":true}
]
''';
