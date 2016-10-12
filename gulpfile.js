var gulp = require('gulp');
var plugins = require('gulp-load-plugins')();

var mainBowerFiles = require('main-bower-files');
var pump = require('pump');

gulp.task('js', function (cb) {
  pump(
    [
      gulp.src(mainBowerFiles()),
      plugins.uglify(),
      gulp.dest('public/scripts/dist')
    ],
    cb
  );
});
