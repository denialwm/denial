part of 'home_surface.dart';

class _HomePager extends StatelessWidget {
  const _HomePager({required this.owner, required this.gridAsync});

  final _HomeSurfaceState owner;
  final AsyncValue<HomeGridState> gridAsync;

  @override
  Widget build(BuildContext context) {
    final gridState = gridAsync.asData?.value;
    return LayoutBuilder(
      builder: (context, constraints) {
        final gridWidth =
            constraints.maxWidth - _HomeSurfaceState._pageHorizontalPadding * 2;
        // Wide panels get more columns (not smaller pages):
        // full-bleed paging and no vertical overflow.
        HomeGridLayout.columns = HomeGridLayout.columnsForViewport(gridWidth);
        final tileWidth =
            (gridWidth -
                HomeGridLayout.gridGap * (HomeGridLayout.columns - 1)) /
            HomeGridLayout.columns;
        // Cell content is fixed-size, so height must not
        // follow width past its cap (phone tiles never
        // reach it and keep the tuned aspect).
        final tileHeight = math.min(
          tileWidth / HomeAppPage.childAspectRatio,
          HomeGridLayout.maxTileHeight,
        );
        final rows = HomeGridLayout.rowsForHeight(
          constraints.maxHeight - _HomeSurfaceState._pageDotsReservedHeight,
          tileHeight,
        );
        final pageSize = HomeGridLayout.columns * rows;
        final gridHeight =
            rows * tileHeight + (rows - 1) * HomeGridLayout.gridGap;
        final rowVisualHeight = math.min(
          tileHeight,
          _HomeSurfaceState._appRowVisualHeight,
        );
        final visualRowsHeight =
            (rows - 1) * (tileHeight + HomeGridLayout.gridGap) +
            rowVisualHeight;
        final pageDotsTop =
            visualRowsHeight +
            math.max(
                  0,
                  constraints.maxHeight -
                      visualRowsHeight -
                      _HomeSurfaceState._pageDotsReservedHeight,
                ) /
                3;
        owner._currentTileWidth = tileWidth;
        owner._currentTileHeight = tileHeight;
        owner._currentRows = rows;

        final slots = gridState?.slots ?? const <HomeGridItem?>[];
        final pageCount = HomeGridLayout.pageCountForSlots(slots, pageSize);
        owner._currentPageCount = pageCount;
        final currentPage = gridState?.page ?? 0;
        final safePage = currentPage.clamp(0, pageCount - 1).toInt();
        owner._syncSafePage(currentPage, safePage);

        final content = gridState == null
            ? gridAsync.hasError
                  ? HomeEmptyState(label: context.l10n.commonError)
                  : HomeEmptyState(label: context.l10n.commonLoading)
            : PageView.builder(
                controller: owner._pageController,
                itemCount: pageCount,
                onPageChanged: (page) =>
                    owner._handlePageChanged(page, pageCount),
                itemBuilder: (context, page) {
                  final start = page * pageSize;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _HomeSurfaceState._pageHorizontalPadding,
                    ),
                    child: HomeAppPage(
                      slots: slots,
                      startIndex: start,
                      pageSize: pageSize,
                      columns: HomeGridLayout.columns,
                      gap: HomeGridLayout.gridGap,
                      tileWidth: tileWidth,
                      tileHeight: tileHeight,
                      draggingSourceIndex: gridState.draggingSourceIndex,
                      resizeModeIndex: owner._resizeModeIndex,
                      onLaunch: owner._launchApp,
                      onDragStart: owner._handleItemDragStart,
                      onDragEnd: owner._handleItemDragEnd,
                      onDragUpdate: (details) {
                        owner._handleItemDragUpdate(details, pageCount);
                      },
                      onResizeModeStart: owner._handleItemResizeModeStart,
                      onResizeModeMove: owner._handleItemResizeModeMove,
                      onResizeModeEnd: owner._handleItemResizeModeEnd,
                      onResizeStart: owner._handleItemResizeStart,
                      onResizeUpdate: owner._handleItemResizeUpdate,
                      onResizeEnd: owner._handleItemResizeEnd,
                    ),
                  );
                },
              );

        return Stack(
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: double.infinity,
                height: gridHeight,
                child: SizedBox.expand(
                  key: owner._gridViewportKey,
                  child: content,
                ),
              ),
            ),
            Positioned(
              top: pageDotsTop,
              left: 0,
              right: 0,
              child: PageDots(count: pageCount, active: safePage),
            ),
          ],
        );
      },
    );
  }
}
