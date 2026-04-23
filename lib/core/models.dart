class StoredOrder {
  final OrderRequest order;
  final OrderStatus status;

  const StoredOrder({required this.order, required this.status});

  factory StoredOrder.fromJson(Map<String, dynamic> json) => StoredOrder(
        order: OrderRequest.fromJson(json['order'] as Map<String, dynamic>),
        status: OrderStatus.fromJson(json['status'] as Map<String, dynamic>),
      );
}

class OrderStatus {
  final String state;
  final DateTime? arrivalDate;
  final DateTime? printedDate;

  const OrderStatus({required this.state, this.arrivalDate, this.printedDate});

  bool get isArrived => state == 'arrived';
  bool get isAccepted => state == 'accepted';

  factory OrderStatus.fromJson(Map<String, dynamic> json) => OrderStatus(
        state: json['state'] as String? ?? 'arrived',
        arrivalDate: _parseDate(json['arrival_date']),
        printedDate: _parseDate(json['printed_date']),
      );
}

DateTime? _parseDate(dynamic v) {
  if (v == null) return null;
  if (v is String && v.isEmpty) return null;
  return DateTime.tryParse(v as String);
}

class OrderRequest {
  final int orderId;
  final int orderNumber;
  final String storeName;
  final String serviceType;
  final double orderTotal;
  final double balanceOwing;
  final String notes;
  final Customer customer;
  final DeliveryAddress? deliveryAddress;
  final List<Payment> payments;
  final List<Item> items;
  final List<Tax> taxes;
  final double tip;

  const OrderRequest({
    required this.orderId,
    required this.orderNumber,
    required this.storeName,
    required this.serviceType,
    required this.orderTotal,
    required this.balanceOwing,
    required this.notes,
    required this.customer,
    required this.deliveryAddress,
    required this.payments,
    required this.items,
    required this.taxes,
    required this.tip,
  });

  String get customerName {
    final full = '${customer.firstName} ${customer.lastName}'.trim();
    return full.isEmpty ? 'Guest' : full;
  }

  bool get isPrepaid => payments.isNotEmpty;

  factory OrderRequest.fromJson(Map<String, dynamic> json) => OrderRequest(
        orderId: (json['order_id'] as num?)?.toInt() ?? 0,
        orderNumber: (json['order_number'] as num?)?.toInt() ?? 0,
        storeName: json['store_name'] as String? ?? '',
        serviceType: json['service_type'] as String? ?? '',
        orderTotal: (json['order_total'] as num?)?.toDouble() ?? 0,
        balanceOwing: (json['balance_owing'] as num?)?.toDouble() ?? 0,
        notes: json['notes'] as String? ?? '',
        customer: Customer.fromJson(
          (json['customer'] as Map<String, dynamic>?) ?? const {},
        ),
        deliveryAddress: json['delivery_address'] == null
            ? null
            : DeliveryAddress.fromJson(
                json['delivery_address'] as Map<String, dynamic>,
              ),
        payments: _list(json['payments'], Payment.fromJson),
        items: _list(json['items'], Item.fromJson),
        taxes: _list(json['taxes'], Tax.fromJson),
        tip: (json['tip'] as num?)?.toDouble() ?? 0,
      );
}

class Customer {
  final String firstName;
  final String lastName;
  final String phone;
  final String email;

  const Customer({
    required this.firstName,
    required this.lastName,
    required this.phone,
    required this.email,
  });

  factory Customer.fromJson(Map<String, dynamic> json) => Customer(
        firstName: json['first_name'] as String? ?? '',
        lastName: json['last_name'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
        email: json['email'] as String? ?? '',
      );
}

class DeliveryAddress {
  final String street;
  final String suite;
  final String city;
  final String state;
  final String zip;

  const DeliveryAddress({
    required this.street,
    required this.suite,
    required this.city,
    required this.state,
    required this.zip,
  });

  factory DeliveryAddress.fromJson(Map<String, dynamic> json) => DeliveryAddress(
        street: json['street'] as String? ?? '',
        suite: json['suite'] as String? ?? '',
        city: json['city'] as String? ?? '',
        state: json['state'] as String? ?? '',
        zip: json['zip'] as String? ?? '',
      );
}

class Payment {
  final String type;
  final double amount;

  const Payment({required this.type, required this.amount});

  factory Payment.fromJson(Map<String, dynamic> json) => Payment(
        type: json['type'] as String? ?? '',
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
      );
}

class Item {
  final String name;
  final String sizeName;
  final int quantity;
  final double price;
  final String notes;
  final List<Modifier> modifiers;

  const Item({
    required this.name,
    required this.sizeName,
    required this.quantity,
    required this.price,
    required this.notes,
    required this.modifiers,
  });

  factory Item.fromJson(Map<String, dynamic> json) => Item(
        name: json['name'] as String? ?? '',
        sizeName: json['size_name'] as String? ?? '',
        quantity: (json['quantity'] as num?)?.toInt() ?? 1,
        price: (json['price'] as num?)?.toDouble() ?? 0,
        notes: json['notes'] as String? ?? '',
        modifiers: _list(json['modifiers'], Modifier.fromJson),
      );
}

class Modifier {
  final String name;
  final String side;
  final int quantity;
  final double price;

  const Modifier({
    required this.name,
    required this.side,
    required this.quantity,
    required this.price,
  });

  factory Modifier.fromJson(Map<String, dynamic> json) => Modifier(
        name: json['name'] as String? ?? '',
        side: json['side'] as String? ?? '',
        quantity: (json['quantity'] as num?)?.toInt() ?? 1,
        price: (json['price'] as num?)?.toDouble() ?? 0,
      );
}

class Tax {
  final String name;
  final double amount;

  const Tax({required this.name, required this.amount});

  factory Tax.fromJson(Map<String, dynamic> json) => Tax(
        name: json['tax_name'] as String? ?? '',
        amount: (json['tax_amount'] as num?)?.toDouble() ?? 0,
      );
}

List<T> _list<T>(dynamic raw, T Function(Map<String, dynamic>) fromJson) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map<String, dynamic>>()
      .map(fromJson)
      .toList(growable: false);
}
