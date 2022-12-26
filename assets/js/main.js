function switch_sub_menu(elem) {
  console.log(elem);

}

document.querySelectorAll('.nav>li>a').forEach(item => {
  item.addEventListener('click', (event) => {
    console.log(event.target);
    let elementA = event.target;
    let subNav = elementA.parentNode.querySelector('.nav');
    let subNavStyleDisplay = subNav.style.display
    subNav.style.display = subNavStyleDisplay === 'flex' ? 'none' : 'flex';
  })

  subNav = item.parentNode.querySelector('.nav')
  if (subNav) {
    let elementSpanIcon = subNav.previousElementSibling;
    if (elementSpanIcon) {
      elementSpanIcon.style.display = 'inline-block';
    }
  }
})