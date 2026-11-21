import SwiftUI

/// 四个根页面 + 窄屏底部悬浮玻璃胶囊 / 平板宽屏左侧悬浮玻璃导航轨（系统 TabBar 隐藏）。
/// 导航栏只在根页面显示；进入详情 / 播放器等二级页面时隐藏。
struct RootTabView: View {
    @State private var tab = Int(ProcessInfo.processInfo.environment["STV_TAB"] ?? "") ?? 0
    @State private var paths = [NavigationPath(), NavigationPath(), NavigationPath(), NavigationPath(), NavigationPath()]
    static let items: [(String, String)] = [("首页", "house.fill"), ("TVBox", "tv.fill"),
                                            ("找剧", "square.grid.2x2.fill"), ("我的", "person.crop.circle.fill")]
    var body: some View {
        GeometryReader { geo in
            let metrics = LayoutMetrics(width: geo.size.width, height: geo.size.height)
            let showNav = paths[tab].isEmpty
            HStack(spacing: 0) {
                if showNav && metrics.useRail {
                    GlassNavigationRail(selection: $tab, items: Self.items, searchTag: 4) { i in
                        if i == tab { paths[i] = NavigationPath() }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                TabView(selection: $tab) {
                    Stack(path: $paths[0], reserveBottomBar: false) { HomeView() }.tag(0)
                    Stack(path: $paths[1], reserveBottomBar: !metrics.useRail) { TVBoxHubView() }.tag(1)
                    Stack(path: $paths[2], reserveBottomBar: !metrics.useRail) { CategoryView() }.tag(2)
                    Stack(path: $paths[3], reserveBottomBar: !metrics.useRail) { ProfileView() }.tag(3)
                    Stack(path: $paths[4], reserveBottomBar: !metrics.useRail) { SearchView() }.tag(4)
                }
                .tint(STVTheme.accent)
                .overlay(alignment: .bottom) {
                    if showNav && !metrics.useRail {
                        GlassTabBar(selection: $tab, items: Self.items, searchTag: 4) { i in
                            if i == tab { paths[i] = NavigationPath() }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .environment(\.layoutMetrics, metrics)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: paths[tab].isEmpty)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: metrics.useRail)
        }
        .onAppear {
            Router.handler = { r in paths[tab].append(r) }
            #if DEBUG
            if ProcessInfo.processInfo.environment["STV_TD_OPEN"] == "1" { Router.push(.tdlib) }
            #endif
        }
        // Cold start: restore a saved TDLib login (no network login, nothing is sent).
        .task { await TDLibService.shared.bootstrap() }
    }
}

private struct Stack<V: View>: View {
    @Binding var path: NavigationPath
    var reserveBottomBar: Bool = true
    @ViewBuilder var content: V
    @Namespace private var ns
    var body: some View {
        NavigationStack(path: $path) {
            content
                .toolbar(.hidden, for: .tabBar)
                .toolbarBackground(.hidden, for: .tabBar)
                .modifier(BottomBarScrollClearance(height: reserveBottomBar ? GlassTabBar.clearance : 0))
                .routes()
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(.hidden, for: .tabBar)
        .environment(\.zoomNS, ns)
    }
}

private struct BottomBarScrollClearance: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        if height == 0 {
            content
        } else if #available(iOS 17.0, *) {
            // Leave room after the last row while letting the scroll view draw behind the bar.
            content.contentMargins(.bottom, height, for: .scrollContent)
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: height)
            }
        }
    }
}

struct GlassTabBar: View {
    static let clearance: CGFloat = 72
    @Binding var selection: Int
    let items: [(String, String)]
    var searchTag: Int? = nil
    var onReselect: (Int) -> Void = { _ in }
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    let on = i == selection
                    Button {
                        if on { onReselect(i) } else { withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { selection = i } }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: items[i].1).font(.system(size: 17, weight: on ? .semibold : .regular)).frame(height: 20)
                            Text(items[i].0).font(.system(size: 11, weight: on ? .semibold : .medium))
                        }
                        .foregroundStyle(on ? STVTheme.text : STVTheme.secondary)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background {
                            if on { Capsule().fill(STVTheme.glassBorder).matchedGeometryEffect(id: "pill", in: ns) }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(items[i].0)
                    .accessibilityIdentifier("tab.\(i)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(STVTheme.glassBorder).allowsHitTesting(false) }

            if let searchTag {
                let searchOn = selection == searchTag
                Button {
                    if searchOn { onReselect(searchTag) } else { withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { selection = searchTag } }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 19, weight: searchOn ? .bold : .semibold))
                        .foregroundStyle(searchOn ? STVTheme.accent : STVTheme.text)
                        .frame(width: 60, height: 60)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay { Circle().strokeBorder(STVTheme.glassBorder).allowsHitTesting(false) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索")
                .accessibilityIdentifier("tab.search")
                .accessibilityAddTraits(searchOn ? .isSelected : [])
            }
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
        .padding(.bottom, -8)
    }
}

/// Vertical floating glass navigation rail for Expanded iPad / Stage Manager widths (>= 840pt).
struct GlassNavigationRail: View {
    @Binding var selection: Int
    let items: [(String, String)]
    var searchTag: Int? = nil
    var onReselect: (Int) -> Void = { _ in }
    @Namespace private var ns
    var body: some View {
        VStack(spacing: 12) {
            if let searchTag {
                let searchOn = selection == searchTag
                Button {
                    if searchOn { onReselect(searchTag) } else { withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { selection = searchTag } }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 19, weight: searchOn ? .bold : .semibold))
                        .foregroundStyle(searchOn ? STVTheme.accent : STVTheme.text)
                        .frame(width: 56, height: 56)
                        .dsBar(28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索")
                .accessibilityIdentifier("tab.search")
                .accessibilityAddTraits(searchOn ? .isSelected : [])
            }

            VStack(spacing: 6) {
                ForEach(items.indices, id: \.self) { i in
                    let on = i == selection
                    Button {
                        if on { onReselect(i) } else { withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { selection = i } }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: items[i].1).font(.system(size: 17, weight: on ? .semibold : .regular)).frame(height: 20)
                            Text(items[i].0).font(.system(size: 11, weight: on ? .semibold : .medium))
                        }
                        .foregroundStyle(on ? STVTheme.text : STVTheme.secondary)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background {
                            if on { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(STVTheme.glassBorder).matchedGeometryEffect(id: "railPill", in: ns) }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(items[i].0)
                    .accessibilityIdentifier("tab.\(i)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(6)
            .dsBar(28)
            Spacer()
        }
        .frame(width: 84)
        .padding(.vertical, 16)
        .padding(.leading, 8)
    }
}
