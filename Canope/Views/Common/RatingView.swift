import SwiftUI

/// A 5-star rating widget. Click a star to set rating, click same star to clear.
struct RatingView: View {
    @Binding var rating: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(star <= rating ? Color.yellow : Color.gray.opacity(0.3))
                    .onTapGesture {
                        rating = (rating == star) ? 0 : star
                    }
            }
        }
    }
}
