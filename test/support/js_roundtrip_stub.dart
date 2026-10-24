/// VM side of [jsRoundTrip]: there is no JS layer, the value is unchanged.
Object? jsRoundTrip(Object? v) => v;

const bool jsRoundTripIsReal = false;
