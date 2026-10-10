#!/usr/bin/env python3
"""Claude 环境卫士 · 开源复刻版 — 程序入口。

运行：python main.py
打包：见 packaging/build.py（PyInstaller 单文件 exe）
"""
import sys

from PySide6.QtWidgets import QApplication

from app import APP_TITLE
from app.ui import MainWindow
from app.ui.theme import MAIN_QSS


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName(APP_TITLE)
    app.setStyleSheet(MAIN_QSS)
    window = MainWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
