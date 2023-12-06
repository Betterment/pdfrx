// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:synchronized/extension.dart';

import '../pdfrx_api.dart';
import 'pdfium_bindings.dart' as pdfium_bindings;
import 'pdfium_interop.dart';
import 'worker.dart';

String _getModuleFileName() {
  if (Platform.isAndroid) return 'libpdfium.so';
  if (Platform.isIOS || Platform.isMacOS) return 'pdfrx.framework/pdfrx';
  if (Platform.isWindows) return 'pdfium.dll';
  if (Platform.isLinux) {
    return '${File(Platform.resolvedExecutable).parent.path}/lib/libpdfium.so';
  }
  throw UnsupportedError('Unsupported platform');
}

final pdfium =
    pdfium_bindings.pdfium(DynamicLibrary.open(_getModuleFileName()));

bool _initialized = false;
final _globalWorker = BackgroundWorker.create();

void _init() {
  if (_initialized) return;
  using((arena) {
    final config = arena.allocate<pdfium_bindings.FPDF_LIBRARY_CONFIG>(
        sizeOf<pdfium_bindings.FPDF_LIBRARY_CONFIG>());
    config.ref.version = 2;
    config.ref.m_pUserFontPaths = nullptr;
    config.ref.m_pIsolate = nullptr;
    config.ref.m_v8EmbedderSlot = 0;
    pdfium.FPDF_InitLibraryWithConfig(config);
  });
  _initialized = true;
}

class PdfDocumentFactoryImpl extends PdfDocumentFactory {
  @override
  Future<PdfDocument> openAsset(String name, {String? password}) async {
    final data = await rootBundle.load(name);
    return await _openData(
      data.buffer.asUint8List(),
      'asset:$name',
      password: password,
    );
  }

  @override
  Future<PdfDocument> openData(
    Uint8List data, {
    String? password,
    void Function()? onDispose,
  }) =>
      _openData(
        data,
        'memory-${data.hashCode}',
        password: password,
        onDispose: onDispose,
      );

  @override
  Future<PdfDocument> openFile(String filePath, {String? password}) async {
    _init();
    return using((arena) {
      return PdfDocumentPdfium.fromPdfDocument(
        pdfium.FPDF_LoadDocument(
            filePath.toUtf8(arena), password?.toUtf8(arena) ?? nullptr),
        sourceName: filePath,
      );
    });
  }

  Future<PdfDocument> _openData(
    Uint8List data,
    String sourceName, {
    String? password,
    int? maxSizeToCacheOnMemory,
    void Function()? onDispose,
  }) async {
    _init();
    return openCustom(
      read: (buffer, position, size) {
        if (position + size > data.length) {
          size = data.length - position;
          if (size < 0) return -1;
        }
        for (int i = 0; i < size; i++) {
          buffer[i] = data[position + i];
        }
        return size;
      },
      fileSize: data.length,
      sourceName: sourceName,
      password: password,
      maxSizeToCacheOnMemory: maxSizeToCacheOnMemory,
      onDispose: onDispose,
    );
  }

  @override
  Future<PdfDocument> openCustom({
    required FutureOr<int> Function(Uint8List buffer, int position, int size)
        read,
    required int fileSize,
    required String sourceName,
    String? password,
    int? maxSizeToCacheOnMemory,
    void Function()? onDispose,
  }) async {
    _init();

    maxSizeToCacheOnMemory ??= 1024 * 1024; // the default is 1MB

    // If the file size is smaller than the specified size, load the file on memory
    if (fileSize < maxSizeToCacheOnMemory) {
      return using((arena) {
        final buffer = calloc.allocate<Uint8>(fileSize);
        read(buffer.asTypedList(fileSize), 0, fileSize);
        return PdfDocumentPdfium.fromPdfDocument(
          pdfium.FPDF_LoadMemDocument(
            buffer.cast<Void>(),
            fileSize,
            password?.toUtf8(arena) ?? nullptr,
          ),
          sourceName: sourceName,
          disposeCallback: () {
            calloc.free(buffer);
            onDispose?.call();
          },
        );
      });
    }

    // Otherwise, load the file on demand
    final fa = FileAccess(fileSize, read);
    final doc = await using((arena) async => (await _globalWorker).compute(
          (params) {
            return pdfium.FPDF_LoadCustomDocument(
              Pointer<pdfium_bindings.FPDF_FILEACCESS>.fromAddress(
                  params.fileAccess),
              Pointer<Char>.fromAddress(params.password),
            ).address;
          },
          (
            fileAccess: fa.fileAccess.address,
            password: password?.toUtf8(arena).address ?? 0,
          ),
        ));
    return PdfDocumentPdfium.fromPdfDocument(
      pdfium_bindings.FPDF_DOCUMENT.fromAddress(doc),
      sourceName: sourceName,
      disposeCallback: () {
        fa.dispose();
        onDispose?.call();
      },
    );
  }
}

extension FpdfUtf8StringExt on String {
  Pointer<Char> toUtf8(Allocator arena) =>
      Pointer.fromAddress(toNativeUtf8(allocator: arena).address);
}

class PdfDocumentPdfium extends PdfDocument {
  final pdfium_bindings.FPDF_DOCUMENT doc;
  final List<PdfPagePdfium?> _pages;
  final void Function()? disposeCallback;
  final _worker = BackgroundWorker.create();

  PdfDocumentPdfium._(
    this.doc, {
    required super.sourceName,
    required super.pageCount,
    required super.isEncrypted,
    required super.allowsCopying,
    required super.allowsPrinting,
    required List<PdfPagePdfium?> pages,
    this.disposeCallback,
  }) : _pages = pages;

  static Future<PdfDocument> fromPdfDocument(pdfium_bindings.FPDF_DOCUMENT doc,
      {required String sourceName, void Function()? disposeCallback}) async {
    final result = await (await _globalWorker).compute(
      (docAddress) {
        final doc = pdfium_bindings.FPDF_DOCUMENT.fromAddress(docAddress);
        return using(
          (arena) {
            final pageCount = pdfium.FPDF_GetPageCount(doc);
            final permissions = pdfium.FPDF_GetDocPermissions(doc);
            final securityHandlerRevision =
                pdfium.FPDF_GetSecurityHandlerRevision(doc);

            final pages = [];
            for (int i = 0; i < pageCount; i++) {
              final page = pdfium.FPDF_LoadPage(doc, i);
              final w = pdfium.FPDF_GetPageWidthF(page);
              final h = pdfium.FPDF_GetPageHeightF(page);
              pages.add(page.address);
              pages.add(w);
              pages.add(h);
            }

            return (
              pageCount: pageCount,
              permissions: permissions,
              securityHandlerRevision: securityHandlerRevision,
              pages: pages,
            );
          },
        );
      },
      doc.address,
    );

    final pdfDoc = PdfDocumentPdfium._(
      doc,
      sourceName: sourceName,
      pageCount: result.pageCount,
      isEncrypted: result.securityHandlerRevision != -1,
      allowsCopying: result.permissions & 32 != 0,
      allowsPrinting: result.permissions & 8 != 0,
      pages: [],
      disposeCallback: disposeCallback,
    );

    for (int i = 0; i < result.pageCount; i++) {
      final page =
          pdfium_bindings.FPDF_PAGE.fromAddress(result.pages[i * 3] as int);
      final w = result.pages[i * 3 + 1] as double;
      final h = result.pages[i * 3 + 2] as double;
      pdfDoc._pages.add(PdfPagePdfium._(
        document: pdfDoc,
        pageNumber: i + 1,
        width: w,
        height: h,
        page: page,
      ));
    }
    return pdfDoc;
  }

  @override
  Future<PdfPage> getPage(int pageNumber) async => _pages[pageNumber - 1]!;

  @override
  Future<void> dispose() async {
    (await _worker).dispose();
    await synchronized(() {
      for (final page in _pages) {
        if (page != null) pdfium.FPDF_ClosePage(page.page);
      }
      pdfium.FPDF_CloseDocument(doc);
    });
    disposeCallback?.call();
  }
}

class PdfPagePdfium extends PdfPage {
  @override
  final PdfDocumentPdfium document;
  @override
  final int pageNumber;
  @override
  final double width;
  @override
  final double height;
  final pdfium_bindings.FPDF_PAGE page;

  PdfPagePdfium._({
    required this.document,
    required this.pageNumber,
    required this.width,
    required this.height,
    required this.page,
  });

  /// FIXME: The implementation is not threaded but it internally divide
  /// the area to be rendered into blocks and render them in order.
  @override
  Future<PdfImage> render({
    int x = 0,
    int y = 0,
    int? width,
    int? height,
    double? fullWidth,
    double? fullHeight,
    Color? backgroundColor,
  }) async {
    fullWidth ??= this.width;
    fullHeight ??= this.height;
    width ??= fullWidth.toInt();
    height ??= fullHeight.toInt();
    backgroundColor ??= Colors.white;
    final buffer = malloc.allocate<Uint8>(width * height * 4);

    await document.synchronized(
      () async {
        await (await document._worker).compute(
          (params) {
            final bmp = pdfium.FPDFBitmap_CreateEx(
              params.width,
              params.height,
              pdfium_bindings.FPDFBitmap_BGRA,
              Pointer.fromAddress(params.buffer),
              params.width * 4,
            );
            pdfium.FPDFBitmap_FillRect(
              bmp,
              0,
              0,
              params.width,
              params.height,
              params.backgroundColor,
            );
            pdfium.FPDF_RenderPageBitmap(
              bmp,
              pdfium_bindings.FPDF_PAGE.fromAddress(params.page),
              -params.x,
              -params.y,
              params.fullWidth,
              params.fullHeight,
              0,
              0,
            );
            pdfium.FPDFBitmap_Destroy(bmp);
          },
          (
            page: page.address,
            buffer: buffer.address,
            x: x,
            y: y,
            width: width!,
            height: height!,
            fullWidth: fullWidth!.toInt(),
            fullHeight: fullHeight!.toInt(),
            backgroundColor: backgroundColor!.value
          ),
        );
      },
    );

    return PdfImagePdfium._(
      width: width,
      height: height,
      buffer: buffer,
    );
  }

  @override
  Future<PdfPageText?> loadText() async {
    return await document.synchronized(() {
      final textPage = pdfium.FPDFText_LoadPage(page);
      final charCount = pdfium.FPDFText_CountChars(textPage);
      return textPage.address == 0
          ? null
          : PdfPageTextPdfium(
              page: this,
              textPage: textPage,
              charCount: charCount,
            );
    });
  }
}

class PdfImagePdfium extends PdfImage {
  @override
  final int width;
  @override
  final int height;
  @override
  ui.PixelFormat get format => ui.PixelFormat.bgra8888;
  @override
  Uint8List get pixels => _buffer.asTypedList(width * height * 4);

  final Pointer<Uint8> _buffer;

  PdfImagePdfium._({
    required this.width,
    required this.height,
    required Pointer<Uint8> buffer,
  }) : _buffer = buffer;

  @override
  void dispose() {
    calloc.free(_buffer);
  }
}

class PdfPageTextPdfium extends PdfPageText {
  final PdfPagePdfium page;
  final pdfium_bindings.FPDF_TEXTPAGE textPage;

  PdfPageTextPdfium({
    required this.page,
    required this.textPage,
    required this.charCount,
  });

  @override
  Future<void> dispose() {
    return page.document
        .synchronized(() => pdfium.FPDFText_ClosePage(textPage));
  }

  @override
  final int charCount;

  @override
  Future<String> getChars({PdfPageTextRange? range}) {
    range ??= fullRange;
    return page.document.synchronized(
      () => using(
        (arena) {
          final buffer = arena.allocate<Uint16>(range!.count * 2);
          pdfium.FPDFText_GetText(
              textPage, range.start, range.count, buffer.cast<UnsignedShort>());
          return String.fromCharCodes(buffer.asTypedList(range.count));
        },
      ),
    );
  }

  /// Get the font size of the text in the specified range.
  /// The font size of the particular character, measured in points (about 1/72 inch).
  /// This is the typographic size of the font (so called "em size").
  Future<List<double>> getFontSizes({PdfPageTextRange? range}) {
    range ??= fullRange;
    return page.document.synchronized(() => List.generate(
        range!.count,
        (index) =>
            pdfium.FPDFText_GetFontSize(textPage, range!.start + index)));
  }

  @override
  Future<List<PdfRect>> getCharBoxes({PdfPageTextRange? range}) {
    range ??= fullRange;
    return page.document.synchronized(
      () => using(
        (arena) {
          final buffer = arena.allocate<Double>(4 * 8);
          return List.generate(
            range!.count,
            (index) {
              pdfium.FPDFText_GetCharBox(
                textPage,
                range!.start + index,
                buffer,
                buffer.offset(8),
                buffer.offset(16),
                buffer.offset(24),
              );
              return _rectFromPointer(buffer);
            },
          );
        },
      ),
    );
  }

  @override
  Future<int> getRectCount({PdfPageTextRange? range}) {
    range ??= fullRange;
    return page.document.synchronized(
        () => pdfium.FPDFText_CountRects(textPage, range!.start, range.count));
  }

  @override
  Future<List<PdfRect>> getRects({PdfPageTextRange? range}) {
    range ??= fullRange;
    return page.document.synchronized(
      () => using(
        (arena) {
          final rectBuffer = arena.allocate<Double>(4 * 8);
          return List.generate(
            range!.count,
            (index) {
              pdfium.FPDFText_GetRect(
                textPage,
                range!.start + index,
                rectBuffer,
                rectBuffer.offset(8),
                rectBuffer.offset(16),
                rectBuffer.offset(24),
              );
              return _rectFromPointer(rectBuffer);
            },
          );
        },
      ),
    );
  }

  @override
  Future<String> getBoundedText(PdfRect rect) => page.document.synchronized(
        () => using(
          (arena) {
            final count = pdfium.FPDFText_GetBoundedText(
              textPage,
              rect.left,
              rect.bottom,
              rect.right,
              rect.top,
              nullptr,
              0,
            );

            final buffer = arena.allocate<UnsignedShort>(count * 2);
            pdfium.FPDFText_GetBoundedText(
              textPage,
              rect.left,
              rect.bottom,
              rect.right,
              rect.top,
              buffer,
              count,
            );
            return String.fromCharCodes(
                buffer.cast<Uint16>().asTypedList(count));
          },
        ),
      );

  @override
  Future<List<PdfLink>> getLinks() async {
    return await page.document.synchronized(() {
      final linkPage = pdfium.FPDFLink_LoadWebLinks(textPage);
      try {
        return using((arena) {
          final rectBuffer = arena.allocate<Double>(4 * 8);
          return List.generate(
            pdfium.FPDFLink_CountWebLinks(linkPage),
            (index) {
              return PdfLink(
                _getLinkUrl(arena, linkPage, index),
                List.generate(
                  pdfium.FPDFLink_CountRects(linkPage, index),
                  (rectIndex) {
                    pdfium.FPDFLink_GetRect(
                      linkPage,
                      index,
                      rectIndex,
                      rectBuffer,
                      rectBuffer.offset(8),
                      rectBuffer.offset(16),
                      rectBuffer.offset(24),
                    );
                    return _rectFromPointer(rectBuffer);
                  },
                ),
              );
            },
          );
        });
      } finally {
        pdfium.FPDFLink_CloseWebLinks(linkPage);
      }
    });
  }

  String _getLinkUrl(
      Allocator alloc, pdfium_bindings.FPDF_PAGELINK linkPage, int linkIndex) {
    final urlLength = pdfium.FPDFLink_GetURL(linkPage, linkIndex, nullptr, 0);
    final urlBuffer = alloc.allocate<UnsignedShort>(urlLength * 2);
    pdfium.FPDFLink_GetURL(linkPage, linkIndex, urlBuffer, urlLength);
    return String.fromCharCodes(
        urlBuffer.cast<Uint16>().asTypedList(urlLength));
  }

  @override
  Future<List<PdfPageTextRange>> findText(
    String text, {
    bool matchCase = false,
    bool wholeWord = false,
  }) =>
      page.document.synchronized(
        () {
          return using(
            (arena) {
              final search = pdfium.FPDFText_FindStart(
                textPage,
                text.toNativeUtf16(allocator: arena).cast(),
                (matchCase ? 1 : 0) | (wholeWord ? 2 : 0),
                0,
              );
              try {
                final matches = <PdfPageTextRange>[];
                do {
                  matches.add(
                    PdfPageTextRange(
                      pdfium.FPDFText_GetSchResultIndex(search),
                      pdfium.FPDFText_GetSchCount(search),
                    ),
                  );
                } while (pdfium.FPDFText_FindNext(search) != 0);
                return matches;
              } finally {
                pdfium.FPDFText_FindClose(search);
              }
            },
          );
        },
      );
}

PdfRect _rectFromPointer(Pointer<Double> buffer) =>
    PdfRect(buffer[0], buffer[3], buffer[2], buffer[3]);

extension _PointerExt<T extends NativeType> on Pointer<T> {
  Pointer<T> offset(int offsetInBytes) =>
      Pointer.fromAddress(address + offsetInBytes);
}
