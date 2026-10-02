"""Build the clickable app:  .venv/bin/python setup.py py2app   (see README.md)"""
import sys

from setuptools import setup

from version import __version__

sys.setrecursionlimit(20000)  # py2app chokes on big packages (numpy/scipy) otherwise

setup(
    app=["menubar.py"],
    name="Lifepoint Transcriber",
    options={
        "py2app": {
            "iconfile": "icon.icns",
            "resources": ["icon/menubarTemplate.png", "icon/menubarTemplate@2x.png", "icon/icon-1024.png"],
            "plist": {
                "CFBundleName": "Lifepoint Transcriber",
                "CFBundleDisplayName": "Lifepoint Transcriber",
                "CFBundleIdentifier": "church.lifepoint.transcriber",
                "CFBundleShortVersionString": __version__,
                "LSUIElement": True,  # menu-bar only, no Dock icon
                "NSMicrophoneUsageDescription": "Lifepoint Transcriber listens to the sound board to create live captions.",
            },
            "includes": ["mlx", "mlx.core", "mlx.nn", "mlx.utils"],
            "packages": ["mlx_whisper", "numpy", "sounddevice", "rumps", "huggingface_hub", "tiktoken", "scipy", "numba", "llvmlite"],
            "excludes": ["torch", "torchgen", "functorch", "sympy", "networkx", "tkinter", "matplotlib", "pytest", "IPython"],
        }
    },
    setup_requires=["py2app"],
)
