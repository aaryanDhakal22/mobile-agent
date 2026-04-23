import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../theme/quicc_colors.dart';
import 'order_detail_view.dart';

/// Full-screen order detail route used by the new-order alert flow and the
/// arrived-queue list. Thin wrapper around [OrderDetailView] that adds a
/// back-arrow AppBar.
class OrderDetailScreen extends StatelessWidget {
  final StoredOrder order;
  final bool confirmable;
  const OrderDetailScreen({
    super.key,
    required this.order,
    this.confirmable = true,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: context.palette.bgCanvas,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: OrderDetailView(
        order: order,
        confirmable: confirmable,
      ),
    );
  }
}
