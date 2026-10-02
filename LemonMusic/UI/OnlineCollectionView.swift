import SwiftUI

struct OnlineCollectionView: View {
    let collection: OnlineCollection
    var body: some View { CollectionDetailView(source: .online(collection)) }
}
