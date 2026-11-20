//
//  MarqueeText.swift
//  Tuno
//
//  Created by Kaan Firat.
//

import AppKit
import SwiftUI

/// One line of text that scrolls in a loop when it doesn't fit: it rests at
/// the start, slides left as a copy follows it in, and rests again. Fits
/// plainly otherwise, and truncates under Reduce Motion.
struct MarqueeText: View {
    let text: String
    let font: NSFont
    var color: Color = .primary

    private let gap: CGFloat = 32
    private let speed: CGFloat = 30
    private let hold: Double = 1.5
    private let fade: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            let scrolls = textWidth > geometry.size.width + 1
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            Group {
                if scrolls {
                    Scroller(text: text, font: Font(font), color: color, distance: textWidth + gap, gap: gap,
                             duration: Double((textWidth + gap) / speed), hold: hold)
                        .frame(width: geometry.size.width, alignment: .leading)
                        .clipped()
                        .mask(edgeFade)
                } else {
                    Text(text)
                        .font(Font(font))
                        .foregroundColor(color)
                        .lineLimit(1)
                        .frame(width: geometry.size.width, alignment: .leading)
                }
            }
            // A new title starts over from rest.
            .id(text)
        }
        .frame(height: ceil(font.ascender - font.descender + font.leading))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: fade)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: fade)
        }
    }

    private struct Scroller: View {
        let text: String
        let font: Font
        let color: Color
        let distance: CGFloat
        let gap: CGFloat
        let duration: Double
        let hold: Double
        @State private var moving = false

        var body: some View {
            HStack(spacing: gap) {
                Text(text)
                Text(text)
            }
            .font(font)
            .foregroundColor(color)
            .fixedSize()
            .offset(x: moving ? -distance : 0)
            .onAppear {
                withAnimation(.linear(duration: duration).delay(hold).repeatForever(autoreverses: false)) {
                    moving = true
                }
            }
        }
    }
}
